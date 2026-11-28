import Foundation

// Copying between the Mac and Dropbox with the normal progress dialog.
// Downloads walk folders themselves, write to "<name>.czpart" and resume it with an HTTP Range
// request, and skip files that are already complete (same size), so a cancelled or broken
// download of a huge shared folder continues where it stopped. Uploads go in 8 MB chunks.

public enum DropboxTransfer {
    static let chunkSize = 8 * 1024 * 1024

    struct RemoteFile {
        let location: DropboxLocation
        let relativePath: String
        let size: Int64
        let modified: Date?
    }

    // MARK: Download

    /// Downloads `items` (files or folders) into `localDir`. Returns the top-level local paths.
    @discardableResult
    public static func download(
        _ items: [DropboxEntry],
        to localDir: String,
        client: DropboxClient = .shared,
        control: TransferControl? = nil,
        progress: ((FileOperationProgress) -> Void)? = nil
    ) async throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(atPath: localDir, withIntermediateDirectories: true)
        let reporter = TransferReporter(handler: progress)
        reporter.progress.isScanning = true

        // 1. Walk the folders (one listing per folder, works for shared folders and links).
        var files: [RemoteFile] = []
        var folders: [String] = []
        for item in items {
            if item.isFolder {
                folders.append(item.name)
                var queue: [(DropboxLocation, String)] = [(item.location, item.name)]
                while !queue.isEmpty {
                    let (loc, rel) = queue.removeFirst()
                    if control?.isCancelled == true { throw TransferCancelledError() }
                    reporter.progress.currentFileName = rel
                    reporter.progress.currentSourcePath = loc.displayPath
                    reporter.emit()
                    for e in try await client.list(loc) {
                        let childRel = rel + "/" + e.name
                        if e.isFolder {
                            folders.append(childRel)
                            queue.append((e.location, childRel))
                        } else {
                            files.append(RemoteFile(location: e.location, relativePath: childRel, size: e.size, modified: e.modified))
                            reporter.progress.totalFiles += 1
                            reporter.progress.totalBytes += e.size
                        }
                    }
                }
            } else {
                files.append(RemoteFile(location: item.location, relativePath: item.name, size: item.size, modified: item.modified))
                reporter.progress.totalFiles += 1
                reporter.progress.totalBytes += item.size
            }
        }
        reporter.progress.isScanning = false
        reporter.emit(force: true)

        // 2. Folders first (empty ones too), then the files.
        for rel in folders {
            try fm.createDirectory(atPath: (localDir as NSString).appendingPathComponent(rel), withIntermediateDirectories: true)
        }
        for file in files {
            try checkpoint(control, reporter)
            let target = (localDir as NSString).appendingPathComponent(file.relativePath)
            reporter.progress.currentFileName = (file.relativePath as NSString).lastPathComponent
            reporter.progress.currentSourcePath = file.location.displayPath
            reporter.progress.currentDestinationPath = target
            reporter.progress.currentFileBytes = 0
            reporter.progress.currentFileTotal = file.size
            reporter.emit()

            // Already complete from an earlier run: skip.
            if let attrs = try? fm.attributesOfItem(atPath: target), (attrs[.size] as? NSNumber)?.int64Value == file.size {
                reporter.progress.processedBytes += file.size
                reporter.progress.processedFiles += 1
                continue
            }
            try fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try await downloadFile(file, to: target, client: client, control: control, reporter: reporter)
            reporter.progress.processedFiles += 1
            reporter.emit()
        }
        reporter.progress.currentFileName = ""
        reporter.emit(force: true)
        return items.map { (localDir as NSString).appendingPathComponent($0.name) }
    }

    static func downloadFile(_ file: RemoteFile, to target: String, client: DropboxClient,
                             control: TransferControl?, reporter: TransferReporter) async throws {
        let fm = FileManager.default
        let part = target + ".czpart"
        let base = reporter.progress.processedBytes
        var attempt = 0
        while true {
            var offset = (try? fm.attributesOfItem(atPath: part)[.size] as? NSNumber)?.int64Value ?? 0
            if offset > file.size { try? fm.removeItem(atPath: part); offset = 0 }
            if !fm.fileExists(atPath: part) { fm.createFile(atPath: part, contents: nil) }

            var request: URLRequest
            switch file.location {
            case .link(let url, let path):
                request = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/sharing/get_shared_link_file")!)
                // A link to a single file takes no path.
                request.setValue(asciiJSON(path.isEmpty ? ["url": url] : ["url": url, "path": path]), forHTTPHeaderField: "Dropbox-API-Arg")
            default:
                guard let path = file.location.apiPath else { throw DropboxError("Cannot download \(file.relativePath).") }
                request = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/download")!)
                request.setValue(asciiJSON(["path": path]), forHTTPHeaderField: "Dropbox-API-Arg")
            }
            request.httpMethod = "POST"
            request.setValue("Bearer " + (try await client.validAccessToken()), forHTTPHeaderField: "Authorization")
            if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }

            do {
                try await StreamingDownload.run(request: request, appendingTo: part, startOffset: offset,
                                                session: client.session, control: control) { written in
                    reporter.progress.currentFileBytes = written
                    reporter.progress.processedBytes = base + written
                    if control?.isPaused == true { reporter.notePaused(true) } else { reporter.notePaused(false) }
                    reporter.emit()
                }
                break
            } catch let e as TransferCancelledError {
                throw e  // the .czpart stays for the next run
            } catch let e as DropboxError where e.status != 0 && e.status != 429 && e.status < 500 {
                throw e
            } catch {
                attempt += 1
                if attempt >= 5 { throw error }
                try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
            }
        }
        if fm.fileExists(atPath: target) { try? fm.removeItem(atPath: target) }
        try fm.moveItem(atPath: part, toPath: target)
        if let modified = file.modified {
            try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: target)
        }
        reporter.progress.processedBytes = base + file.size
    }

    // MARK: Upload

    /// Uploads local files / folders into the Dropbox folder `destination`.
    public static func upload(
        _ localPaths: [String],
        to destination: DropboxLocation,
        options: FileOperationOptions = FileOperationOptions(),
        client: DropboxClient = .shared,
        control: TransferControl? = nil,
        progress: ((FileOperationProgress) -> Void)? = nil
    ) async throws {
        guard destination.supportsWrite else { throw DropboxError("This Dropbox place is read-only.") }
        let fm = FileManager.default
        let reporter = TransferReporter(handler: progress)
        reporter.progress.isScanning = true

        var folders: [DropboxLocation] = []
        var files: [(local: String, remote: DropboxLocation, size: Int64)] = []
        for top in localPaths {
            let name = (top as NSString).lastPathComponent
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: top, isDirectory: &isDir) else { continue }
            let remoteTop = destination.appending(name)
            if isDir.boolValue {
                folders.append(remoteTop)
                guard let e = fm.enumerator(atPath: top) else { continue }
                while let rel = e.nextObject() as? String {
                    let local = (top as NSString).appendingPathComponent(rel)
                    var remote = remoteTop
                    for part in rel.split(separator: "/") { remote = remote.appending(String(part)) }
                    var st = stat()
                    guard lstat(local, &st) == 0 else { continue }
                    if (st.st_mode & S_IFMT) == S_IFDIR {
                        folders.append(remote)
                    } else if (st.st_mode & S_IFMT) == S_IFREG {
                        if (local as NSString).lastPathComponent == ".DS_Store" { continue }
                        files.append((local, remote, Int64(st.st_size)))
                        reporter.progress.totalFiles += 1
                        reporter.progress.totalBytes += Int64(st.st_size)
                    }
                }
            } else {
                let size = ((try? fm.attributesOfItem(atPath: top)[.size]) as? NSNumber)?.int64Value ?? 0
                files.append((top, remoteTop, size))
                reporter.progress.totalFiles += 1
                reporter.progress.totalBytes += size
            }
        }
        reporter.progress.isScanning = false
        reporter.emit(force: true)

        for folder in folders {
            try checkpoint(control, reporter)
            do { try await client.createFolder(folder) } catch let e as DropboxError where e.message.contains("exists") || e.message.contains("conflict") {
                // Already there: merge into it.
            }
        }
        for file in files {
            try checkpoint(control, reporter)
            reporter.progress.currentFileName = (file.local as NSString).lastPathComponent
            reporter.progress.currentSourcePath = file.local
            reporter.progress.currentDestinationPath = file.remote.displayPath
            reporter.progress.currentFileBytes = 0
            reporter.progress.currentFileTotal = file.size
            reporter.emit()

            let mode: String
            var autorename = false
            switch options.overwritePolicy {
            case .skipAll, .overwriteOlder:
                if await client.exists(file.remote) {
                    reporter.progress.processedBytes += file.size
                    reporter.progress.processedFiles += 1
                    continue
                }
                mode = "add"
            case .autoRenameSource, .autoRenameTarget:
                mode = "add"; autorename = true
            case .overwriteAll, .ask:
                mode = "overwrite"
            }
            try await uploadFile(local: file.local, remote: file.remote, size: file.size, mode: mode, autorename: autorename,
                                 client: client, control: control, reporter: reporter)
            reporter.progress.processedFiles += 1
            reporter.emit()
        }
        reporter.emit(force: true)
    }

    static func uploadFile(local: String, remote: DropboxLocation, size: Int64, mode: String, autorename: Bool,
                           client: DropboxClient, control: TransferControl?, reporter: TransferReporter) async throws {
        guard let path = remote.apiPath else { throw DropboxError("Read-only place.") }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: local))
        defer { try? handle.close() }
        let base = reporter.progress.processedBytes
        let modified = (try? FileManager.default.attributesOfItem(atPath: local)[.modificationDate] as? Date) ?? Date()
        let commit: [String: Any] = [
            "path": path, "mode": mode, "autorename": autorename, "mute": true,
            "client_modified": DropboxEntry.dateParser.string(from: modified),
        ]

        if size <= Int64(chunkSize) {
            let data = try handle.readToEnd() ?? Data()
            _ = try await content("files/upload", arg: commit, body: data, client: client)
            reporter.progress.processedBytes = base + size
            reporter.progress.currentFileBytes = size
            return
        }

        var offset: Int64 = 0
        var sessionID: String?
        while offset < size {
            try checkpoint(control, reporter)
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            if let id = sessionID {
                _ = try await content("files/upload_session/append_v2",
                                      arg: ["cursor": ["session_id": id, "offset": offset], "close": false],
                                      body: chunk, client: client)
            } else {
                let json = try await content("files/upload_session/start", arg: ["close": false], body: chunk, client: client)
                sessionID = json["session_id"] as? String
                guard sessionID != nil else { throw DropboxError("Dropbox did not start the upload.") }
            }
            offset += Int64(chunk.count)
            reporter.progress.currentFileBytes = offset
            reporter.progress.processedBytes = base + offset
            reporter.emit()
        }
        guard let id = sessionID else { throw DropboxError("Upload of \(local) failed.") }
        _ = try await content("files/upload_session/finish",
                              arg: ["cursor": ["session_id": id, "offset": offset], "commit": commit],
                              body: Data(), client: client)
    }

    /// POST to content.dropboxapi.com with the argument in the Dropbox-API-Arg header.
    static func content(_ endpoint: String, arg: [String: Any], body: Data, client: DropboxClient) async throws -> [String: Any] {
        for attempt in 0..<5 {
            var req = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/" + endpoint)!)
            req.httpMethod = "POST"
            req.setValue("Bearer " + (try await client.validAccessToken()), forHTTPHeaderField: "Authorization")
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            req.setValue(asciiJSON(arg), forHTTPHeaderField: "Dropbox-API-Arg")
            let (data, resp) = try await client.session.upload(for: req, from: body)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            }
            if (status == 429 || status >= 500), attempt < 4 {
                try await Task.sleep(nanoseconds: UInt64(1 << attempt) * 1_000_000_000)
                continue
            }
            throw DropboxClient.error(from: data, status: status)
        }
        throw DropboxError("Dropbox is busy, try again later.", status: 429)
    }

    // MARK: Inside Dropbox

    /// Server-side copy / move between two writable Dropbox folders (no download).
    public static func copyWithinDropbox(_ items: [DropboxEntry], to destination: DropboxLocation, isMove: Bool,
                                         client: DropboxClient = .shared, control: TransferControl? = nil,
                                         progress: ((FileOperationProgress) -> Void)? = nil) async throws {
        let reporter = TransferReporter(handler: progress)
        reporter.progress.totalFiles = items.count
        for item in items {
            try checkpoint(control, reporter)
            let target = destination.appending(item.name)
            reporter.progress.currentFileName = item.name
            reporter.progress.currentSourcePath = item.location.displayPath
            reporter.progress.currentDestinationPath = target.displayPath
            reporter.emit(force: true)
            if isMove { try await client.move(item.location, to: target) } else { try await client.copy(item.location, to: target) }
            reporter.progress.processedFiles += 1
        }
        reporter.emit(force: true)
    }

    // MARK: Helpers

    static func checkpoint(_ control: TransferControl?, _ reporter: TransferReporter) throws {
        guard let control else { return }
        if control.isPaused { reporter.notePaused(true); reporter.emit(force: true) }
        let ok = control.checkpoint()
        reporter.notePaused(false)
        if !ok { throw TransferCancelledError() }
    }

    /// JSON for the Dropbox-API-Arg header: non-ASCII characters must be \u-escaped.
    public static func asciiJSON(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        var out = ""
        for unit in json.utf16 {
            if unit < 0x80 {
                out.append(Character(UnicodeScalar(unit)!))
            } else {
                out += String(format: "\\u%04x", unit)
            }
        }
        return out
    }
}

/// One HTTP download streamed into a file, with pause (task suspend) and cancel.
final class StreamingDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let handle: FileHandle
    private var written: Int64
    private let onProgress: (Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var status = 0
    private var errorBody = Data()
    private let lock = NSLock()

    private init(handle: FileHandle, startOffset: Int64, onProgress: @escaping (Int64) -> Void) {
        self.handle = handle
        self.written = startOffset
        self.onProgress = onProgress
    }

    static func run(request: URLRequest, appendingTo path: String, startOffset: Int64, session: URLSession,
                    control: TransferControl?, onProgress: @escaping (Int64) -> Void) async throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(startOffset))
        try handle.seek(toOffset: UInt64(startOffset))
        let delegate = StreamingDownload(handle: handle, startOffset: startOffset, onProgress: onProgress)
        let delegateSession = URLSession(configuration: session.configuration, delegate: delegate, delegateQueue: nil)
        defer { delegateSession.finishTasksAndInvalidate() }
        let task = delegateSession.dataTask(with: request)

        // Pause / cancel watcher.
        let watcher = Task.detached {
            var suspended = false
            while !Task.isCancelled {
                if let control {
                    if control.isCancelled { task.cancel(); return }
                    if control.isPaused && !suspended { task.suspend(); suspended = true }
                    if !control.isPaused && suspended { task.resume(); suspended = false }
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        defer { watcher.cancel() }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            delegate.lock.lock(); delegate.continuation = cont; delegate.lock.unlock()
            task.resume()
        }
        if control?.isCancelled == true { throw TransferCancelledError() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Asked for a range but got the whole file: start the part file over.
        if status == 200 && written > 0 {
            try? handle.truncate(atOffset: 0)
            try? handle.seek(toOffset: 0)
            written = 0
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard status == 200 || status == 206 else {
            errorBody.append(data)
            return
        }
        do {
            try handle.write(contentsOf: data)
            written += Int64(data.count)
            onProgress(written)
        } catch {
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        if let error {
            if (error as NSError).code == NSURLErrorCancelled {
                cont?.resume(throwing: TransferCancelledError())
            } else {
                cont?.resume(throwing: error)
            }
        } else if status == 200 || status == 206 {
            cont?.resume()
        } else {
            cont?.resume(throwing: DropboxClient.error(from: errorBody, status: status))
        }
    }
}
