import Foundation
import Darwin

public enum OverwritePolicy: String, CaseIterable, Codable, Sendable {
    case ask = "ask"
    case overwriteAll = "overwriteAll"
    case skipAll = "skipAll"
    case overwriteOlder = "overwriteOlder"
    case autoRenameSource = "autoRenameSource"
    case autoRenameTarget = "autoRenameTarget"

    public var displayName: String {
        switch self {
        case .ask:
            return "Ask user"
        case .overwriteAll:
            return "Overwrite all"
        case .skipAll:
            return "Skip all"
        case .overwriteOlder:
            return "Overwrite all older"
        case .autoRenameSource:
            return "Auto-rename copied"
        case .autoRenameTarget:
            return "Auto-rename target"
        }
    }
}

public struct FileOperationOptions: Codable, Sendable {
    public var targetMask: String
    public var overwritePolicy: OverwritePolicy
    public var preserveTimestamps: Bool
    public var preservePermissions: Bool
    public var verifyAfterCopy: Bool
    public var onlyCopyMatchingFilter: String?

    public init(
        targetMask: String = "*.*",
        overwritePolicy: OverwritePolicy = .overwriteAll,
        preserveTimestamps: Bool = true,
        preservePermissions: Bool = true,
        verifyAfterCopy: Bool = false,
        onlyCopyMatchingFilter: String? = nil
    ) {
        self.targetMask = targetMask
        self.overwritePolicy = overwritePolicy
        self.preserveTimestamps = preserveTimestamps
        self.preservePermissions = preservePermissions
        self.verifyAfterCopy = verifyAfterCopy
        self.onlyCopyMatchingFilter = onlyCopyMatchingFilter
    }
}

public struct FileOperationProgress: Sendable {
    public var currentFileName: String
    public var processedFiles: Int
    public var totalFiles: Int
    public var processedBytes: Int64
    public var totalBytes: Int64
    public var bytesPerSecond: Double
    /// Full paths of the item being copied right now.
    public var currentSourcePath: String = ""
    public var currentDestinationPath: String = ""
    /// Bytes of the current file done / in total.
    public var currentFileBytes: Int64 = 0
    public var currentFileTotal: Int64 = 0
    /// Running time without pauses.
    public var elapsedSeconds: TimeInterval = 0
    /// Still counting files and bytes before the copy starts.
    public var isScanning: Bool = false

    public var currentFileFraction: Double {
        currentFileTotal > 0 ? min(1, Double(currentFileBytes) / Double(currentFileTotal)) : 0
    }

    /// Estimated seconds left at the current speed (nil while unknown).
    public var remainingSeconds: TimeInterval? {
        guard bytesPerSecond > 1, totalBytes > processedBytes else { return nil }
        return Double(totalBytes - processedBytes) / bytesPerSecond
    }

    public init(
        currentFileName: String = "",
        processedFiles: Int = 0,
        totalFiles: Int = 0,
        processedBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        bytesPerSecond: Double = 0
    ) {
        self.currentFileName = currentFileName
        self.processedFiles = processedFiles
        self.totalFiles = totalFiles
        self.processedBytes = processedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
    }

    public var fractionCompleted: Double {
        if totalBytes > 0 {
            return min(1.0, max(0.0, Double(processedBytes) / Double(totalBytes)))
        }
        if totalFiles > 0 {
            return min(1.0, max(0.0, Double(processedFiles) / Double(totalFiles)))
        }
        return 0
    }
}

public struct AttributeChangeRequest: Sendable {
    public var posixPermissions: UInt16?
    public var isLocked: Bool?
    public var isHidden: Bool?
    public var modificationDate: Date?
    public var creationDate: Date?
    public var finderTagColor: FinderTagColor?
    public var descriptionComment: String?
    public var recurseSubdirectories: Bool

    public init(
        posixPermissions: UInt16? = nil,
        isLocked: Bool? = nil,
        isHidden: Bool? = nil,
        modificationDate: Date? = nil,
        creationDate: Date? = nil,
        finderTagColor: FinderTagColor? = nil,
        descriptionComment: String? = nil,
        recurseSubdirectories: Bool = false
    ) {
        self.posixPermissions = posixPermissions
        self.isLocked = isLocked
        self.isHidden = isHidden
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.finderTagColor = finderTagColor
        self.descriptionComment = descriptionComment
        self.recurseSubdirectories = recurseSubdirectories
    }
}

public enum FileSystemEngine {
    // MARK: - Directory Listing

    public static func listDirectory(
        at path: String,
        showHidden: Bool = true,
        includeParentEntry: Bool = true
    ) throws -> [FileItem] {
        let fm = FileManager.default
        let standardizedPath = (path as NSString).standardizingPath
        let entryNames = try fm.contentsOfDirectory(atPath: standardizedPath)
        let descriptions = loadDescriptionMap(inDirectory: standardizedPath)

        var items: [FileItem] = []
        items.reserveCapacity(entryNames.count + 1)

        if includeParentEntry && standardizedPath != "/" {
            let parentPath = (standardizedPath as NSString).deletingLastPathComponent
            items.append(FileItem.parentEntry(for: parentPath.isEmpty ? "/" : parentPath))
        }

        for name in entryNames {
            let fullPath = (standardizedPath as NSString).appendingPathComponent(name)
            if let item = inspectFileItem(
                atPath: fullPath,
                name: name,
                descriptionComment: descriptions[name] ?? ""
            ) {
                if !showHidden && item.isHidden {
                    continue
                }
                items.append(item)
            }
        }

        return items
    }

    public static func inspectFileItem(
        atPath fullPath: String,
        name: String? = nil,
        descriptionComment: String = "",
        relativeDisplayPath: String? = nil
    ) -> FileItem? {
        let itemName = name ?? (fullPath as NSString).lastPathComponent
        var lstatBuf = stat()
        guard lstat(fullPath, &lstatBuf) == 0 else {
            return nil
        }

        let mode = lstatBuf.st_mode
        let isSymlink = (mode & S_IFMT) == S_IFLNK
        var targetStatBuf = lstatBuf
        var symlinkTarget: String? = nil

        if isSymlink {
            symlinkTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: fullPath)
            var resolvedBuf = stat()
            if stat(fullPath, &resolvedBuf) == 0 {
                targetStatBuf = resolvedBuf
            }
        }

        let isDirectory = (targetStatBuf.st_mode & S_IFMT) == S_IFDIR
        let posixPerm = UInt16(lstatBuf.st_mode & 0o7777)
        let isExecutable = !isDirectory && ((posixPerm & 0o111) != 0)
        let isLocked = (lstatBuf.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE)) != 0
        let isHiddenFlag = (lstatBuf.st_flags & UInt32(UF_HIDDEN)) != 0
        let isHidden = itemName.hasPrefix(".") || isHiddenFlag

        let modDate = Date(
            timeIntervalSince1970: TimeInterval(lstatBuf.st_mtimespec.tv_sec)
                + TimeInterval(lstatBuf.st_mtimespec.tv_nsec) / 1_000_000_000.0
        )
        let birthDate = Date(
            timeIntervalSince1970: TimeInterval(lstatBuf.st_birthtimespec.tv_sec)
                + TimeInterval(lstatBuf.st_birthtimespec.tv_nsec) / 1_000_000_000.0
        )

        let ownerName = userName(forUID: lstatBuf.st_uid)
        let groupName = groupName(forGID: lstatBuf.st_gid)

        let tagColor: FinderTagColor = .none

        return FileItem(
            name: itemName,
            fullPath: fullPath,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            symlinkTarget: symlinkTarget,
            isHidden: isHidden,
            isLocked: isLocked,
            isExecutable: isExecutable,
            isParentDirectoryEntry: false,
            size: isDirectory ? 0 : Int64(targetStatBuf.st_size),
            calculatedDirectorySize: nil,
            modificationDate: modDate,
            creationDate: birthDate,
            posixPermissions: posixPerm,
            ownerName: ownerName,
            groupName: groupName,
            finderComment: "",
            descriptionComment: descriptionComment,
            finderTagColor: tagColor,
            relativeDisplayPath: relativeDisplayPath
        )
    }

    // MARK: - Branch View (Cmd+B Flat Recursive View)

    public static func listBranchView(
        at rootPath: String,
        showHidden: Bool = true,
        selectedSubfoldersOnly: [String]? = nil
    ) -> [FileItem] {
        let fm = FileManager.default
        let standardizedRoot = (rootPath as NSString).standardizingPath
        var results: [FileItem] = []

        if standardizedRoot != "/" {
            let parentPath = (standardizedRoot as NSString).deletingLastPathComponent
            results.append(FileItem.parentEntry(for: parentPath.isEmpty ? "/" : parentPath))
        }

        let rootsToScan: [String]
        if let subdirs = selectedSubfoldersOnly, !subdirs.isEmpty {
            rootsToScan = subdirs
        } else {
            rootsToScan = [standardizedRoot]
        }

        for scanBase in rootsToScan {
            guard let enumerator = fm.enumerator(atPath: scanBase) else { continue }
            while let relObj = enumerator.nextObject() as? String {
                let fullPath = (scanBase as NSString).appendingPathComponent(relObj)
                let components = relObj.split(separator: "/")
                if !showHidden && components.contains(where: { $0.hasPrefix(".") }) {
                    continue
                }
                let relFromRoot: String
                if fullPath.hasPrefix(standardizedRoot + "/") {
                    relFromRoot = String(fullPath.dropFirst(standardizedRoot.count + 1))
                } else {
                    relFromRoot = relObj
                }
                if let item = inspectFileItem(
                    atPath: fullPath,
                    name: (fullPath as NSString).lastPathComponent,
                    relativeDisplayPath: relFromRoot
                ), !item.isDirectory {
                    results.append(item)
                }
            }
        }

        return results
    }

    // MARK: - Recursive Directory Size Calculation (Space / Alt+Shift+Enter)

    public static func calculateDirectorySize(
        at path: String,
        onProgress: ((Int64) -> Bool)? = nil
    ) -> Int64 {
        guard let cStr = strdup(path) else { return 0 }
        defer { free(cStr) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cStr, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return 0 }
        defer { fts_close(fts) }

        var total: Int64 = 0
        var counter = 0
        var lastReportTime = CFAbsoluteTimeGetCurrent()

        while let entry = fts_read(fts) {
            let info = Int32(entry.pointee.fts_info)
            if info == FTS_F, let st = entry.pointee.fts_statp {
                total += Int64(st.pointee.st_size)
            }
            counter += 1
            if counter >= 2048, let cb = onProgress {
                counter = 0
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastReportTime >= 0.12 {
                    lastReportTime = now
                    if !cb(total) {
                        break
                    }
                }
            }
        }
        return total
    }

    // MARK: - Wildcard Mask Transformation (Total Commander F5/F6 Target Mask)

    /// Transforms `sourceName` according to a Total Commander mask such as `*.*`, `*.bak`, `copy_*.*`, `fixed.txt`
    public static func transformFileName(_ sourceName: String, withMask mask: String) -> String {
        let trimmed = mask.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "*.*" || trimmed == "*" {
            return sourceName
        }
        guard trimmed.contains("*") || trimmed.contains("?") else {
            return trimmed
        }

        let dotIndex = sourceName.lastIndex(of: ".")
        let hasExt = dotIndex != nil && dotIndex != sourceName.startIndex
        let srcStem = hasExt ? String(sourceName[..<dotIndex!]) : sourceName
        let srcExt = hasExt ? String(sourceName[sourceName.index(after: dotIndex!)...]) : ""

        let maskDotIndex = trimmed.lastIndex(of: ".")
        if let mDot = maskDotIndex {
            let maskStem = String(trimmed[..<mDot])
            let maskExt = String(trimmed[trimmed.index(after: mDot)...])
            let newStem = applyPartMask(source: srcStem, mask: maskStem)
            let newExt = applyPartMask(source: srcExt, mask: maskExt)
            return newExt.isEmpty ? newStem : "\(newStem).\(newExt)"
        } else {
            return applyPartMask(source: sourceName, mask: trimmed)
        }
    }

    private static func applyPartMask(source: String, mask: String) -> String {
        if mask == "*" { return source }
        var out = ""
        let srcChars = Array(source)
        var srcIdx = 0
        for ch in mask {
            if ch == "*" {
                if srcIdx < srcChars.count {
                    out.append(contentsOf: srcChars[srcIdx...])
                    srcIdx = srcChars.count
                }
            } else if ch == "?" {
                if srcIdx < srcChars.count {
                    out.append(srcChars[srcIdx])
                    srcIdx += 1
                }
            } else {
                out.append(ch)
                if srcIdx < srcChars.count {
                    srcIdx += 1
                }
            }
        }
        return out
    }

    // MARK: - Copy and Move Operations (F5 / F6 / Shift+F5 / Shift+F6)

    /// Copy (F5) / move (F6). Runs `TransferEngine`: byte-level progress, pause / cancel via
    /// `control`, folders merge into existing ones, same-volume moves are renames.
    @discardableResult
    public static func copyOrMoveItems(
        sources: [String],
        toDestinationDirectory destDir: String,
        isMove: Bool,
        options: FileOperationOptions = FileOperationOptions(),
        control: TransferControl? = nil,
        progressHandler: ((FileOperationProgress) -> Void)? = nil
    ) throws -> [String] {
        try TransferEngine.copyOrMove(sources: sources, to: destDir, isMove: isMove, options: options,
                                      control: control, progress: progressHandler)
    }

    public static func uniqueFilePath(for path: String) -> String {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) { return path }
        let dir = (path as NSString).deletingLastPathComponent
        let filename = (path as NSString).lastPathComponent
        let dotIdx = filename.lastIndex(of: ".")
        let hasExt = dotIdx != nil && dotIdx != filename.startIndex
        let stem = hasExt ? String(filename[..<dotIdx!]) : filename
        let ext = hasExt ? String(filename[filename.index(after: dotIdx!)...]) : ""

        var counter = 2
        while true {
            let candidateName = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            let candidatePath = (dir as NSString).appendingPathComponent(candidateName)
            if !fm.fileExists(atPath: candidatePath) {
                return candidatePath
            }
            counter += 1
        }
    }

    // MARK: - F7 Create Directories (Multi-folder `|` & Template Support)

    /// Supports Total Commander F7 syntax: `folder1|folder2|nested/folder3` and `[Y]`, `[M]`, `[D]`, `[h]`, `[m]`, `[s]`
    @discardableResult
    public static func createDirectories(
        expression: String,
        in baseDirectory: String,
        referenceDate: Date = Date()
    ) throws -> [String] {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: referenceDate)
        let yStr = String(format: "%04d", comps.year ?? 2026)
        let mStr = String(format: "%02d", comps.month ?? 1)
        let dStr = String(format: "%02d", comps.day ?? 1)
        let hStr = String(format: "%02d", comps.hour ?? 0)
        let minStr = String(format: "%02d", comps.minute ?? 0)
        let sStr = String(format: "%02d", comps.second ?? 0)

        let expanded = expression
            .replacingOccurrences(of: "[YMD]", with: "\(yStr)-\(mStr)-\(dStr)")
            .replacingOccurrences(of: "[Y]", with: yStr)
            .replacingOccurrences(of: "[M]", with: mStr)
            .replacingOccurrences(of: "[D]", with: dStr)
            .replacingOccurrences(of: "[hms]", with: "\(hStr)-\(minStr)-\(sStr)")
            .replacingOccurrences(of: "[h]", with: hStr)
            .replacingOccurrences(of: "[m]", with: minStr)
            .replacingOccurrences(of: "[s]", with: sStr)

        let parts = expanded
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var created: [String] = []
        let fm = FileManager.default
        for part in parts {
            let fullPath: String
            if part.hasPrefix("/") {
                fullPath = part
            } else {
                fullPath = (baseDirectory as NSString).appendingPathComponent(part)
            }
            try fm.createDirectory(atPath: fullPath, withIntermediateDirectories: true)
            created.append(fullPath)
        }
        return created
    }

    // MARK: - F8 / Shift+F8 Delete (Trash, Permanent, Secure Wipe)

    public static func deleteItems(
        atPaths paths: [String],
        moveToTrash: Bool,
        secureWipe: Bool = false
    ) throws {
        let fm = FileManager.default
        for path in paths {
            // Clear immutable flag if present
            chflags(path, 0)
            if moveToTrash && !secureWipe {
                let url = URL(fileURLWithPath: path)
                do {
                    try fm.trashItem(at: url, resultingItemURL: nil)
                } catch {
                    try removeExistingUnlockingIfNeeded(atPath: path)
                }
            } else {
                if secureWipe {
                    secureZeroOverwrite(atPath: path)
                }
                try removeExistingUnlockingIfNeeded(atPath: path)
            }
        }
    }

    private static func secureZeroOverwrite(atPath path: String) {
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        if (st.st_mode & S_IFMT) == S_IFREG && st.st_size > 0 {
            if let handle = FileHandle(forWritingAtPath: path) {
                defer { try? handle.close() }
                let chunkSize = 65_536
                let zeroChunk = Data(repeating: 0, count: chunkSize)
                var remaining = Int(st.st_size)
                try? handle.seek(toOffset: 0)
                while remaining > 0 {
                    let count = min(chunkSize, remaining)
                    if count == chunkSize {
                        try? handle.write(contentsOf: zeroChunk)
                    } else {
                        try? handle.write(contentsOf: Data(repeating: 0, count: count))
                    }
                    remaining -= count
                }
                try? handle.synchronize()
            }
        }
    }

    public static func removeExistingUnlockingIfNeeded(atPath path: String) throws {
        chflags(path, 0)
        chmod(path, 0o700)
        try FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Change Attributes / Permissions / Timestamps / Comments

    public static func changeAttributes(
        forPaths paths: [String],
        request: AttributeChangeRequest
    ) throws {
        let fm = FileManager.default
        for path in paths {
            try applySingleAttributeChange(atPath: path, request: request)
            if request.recurseSubdirectories {
                var st = stat()
                if lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR {
                    if let enumerator = fm.enumerator(atPath: path) {
                        while let rel = enumerator.nextObject() as? String {
                            let childPath = (path as NSString).appendingPathComponent(rel)
                            try? applySingleAttributeChange(atPath: childPath, request: request)
                        }
                    }
                }
            }
        }
    }

    private static func applySingleAttributeChange(atPath path: String, request: AttributeChangeRequest) throws {
        let fm = FileManager.default
        // Unlock first if we need to modify attributes
        var currentStat = stat()
        let hasStat = lstat(path, &currentStat) == 0
        if hasStat && (currentStat.st_flags & UInt32(UF_IMMUTABLE)) != 0 {
            chflags(path, currentStat.st_flags & ~UInt32(UF_IMMUTABLE))
        }

        if let perms = request.posixPermissions {
            chmod(path, mode_t(perms & 0o7777))
        }

        var dict: [FileAttributeKey: Any] = [:]
        if let mod = request.modificationDate {
            dict[.modificationDate] = mod
        }
        if let cre = request.creationDate {
            dict[.creationDate] = cre
        }
        if !dict.isEmpty {
            try fm.setAttributes(dict, ofItemAtPath: path)
        }

        if let tagColor = request.finderTagColor {
            var url = URL(fileURLWithPath: path)
            var values = URLResourceValues()
            values.labelNumber = tagColor.rawValue
            try? url.setResourceValues(values)
        }

        if let comment = request.descriptionComment {
            let dir = (path as NSString).deletingLastPathComponent
            let name = (path as NSString).lastPathComponent
            try setDescriptionComment(comment, forFileName: name, inDirectory: dir)
        }

        if hasStat {
            var flags = currentStat.st_flags
            if let hidden = request.isHidden {
                if hidden {
                    flags |= UInt32(UF_HIDDEN)
                } else {
                    flags &= ~UInt32(UF_HIDDEN)
                }
            }
            if let locked = request.isLocked {
                if locked {
                    flags |= UInt32(UF_IMMUTABLE)
                } else {
                    flags &= ~UInt32(UF_IMMUTABLE)
                }
            }
            chflags(path, flags)
        }
    }

    // MARK: - Total Commander `descript.ion` File Comments

    public static func loadDescriptionMap(inDirectory directoryPath: String) -> [String: String] {
        let descFile = (directoryPath as NSString).appendingPathComponent("descript.ion")
        guard let content = try? String(contentsOfFile: descFile, encoding: .utf8) else {
            return [:]
        }
        var map: [String: String] = [:]
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("\"") {
                let afterQuote = line.index(after: line.startIndex)
                if let closingQuote = line[afterQuote...].firstIndex(of: "\"") {
                    let filename = String(line[afterQuote..<closingQuote])
                    let restStart = line.index(after: closingQuote)
                    let comment = String(line[restStart...]).trimmingCharacters(in: .whitespaces)
                    map[filename] = comment
                }
            } else {
                if let firstSpace = line.firstIndex(of: " ") {
                    let filename = String(line[..<firstSpace])
                    let comment = String(line[line.index(after: firstSpace)...]).trimmingCharacters(in: .whitespaces)
                    map[filename] = comment
                }
            }
        }
        return map
    }

    public static func setDescriptionComment(
        _ comment: String,
        forFileName fileName: String,
        inDirectory directoryPath: String
    ) throws {
        var map = loadDescriptionMap(inDirectory: directoryPath)
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            map.removeValue(forKey: fileName)
        } else {
            map[fileName] = trimmed
        }

        let descFile = (directoryPath as NSString).appendingPathComponent("descript.ion")
        if map.isEmpty {
            if FileManager.default.fileExists(atPath: descFile) {
                try? FileManager.default.removeItem(atPath: descFile)
            }
            return
        }

        let lines = map.keys.sorted().compactMap { key -> String? in
            guard let val = map[key], !val.isEmpty else { return nil }
            if key.contains(" ") {
                return "\"\(key)\" \(val)"
            } else {
                return "\(key) \(val)"
            }
        }
        let output = lines.joined(separator: "\n") + "\n"
        try output.write(toFile: descFile, atomically: true, encoding: .utf8)
    }

    // MARK: - Helpers

    nonisolated(unsafe) private static var uidCache: [uid_t: String] = [:]
    nonisolated(unsafe) private static var gidCache: [gid_t: String] = [:]

    private static func userName(forUID uid: uid_t) -> String {
        if let cached = uidCache[uid] { return cached }
        let name: String
        if let pw = getpwuid(uid), let cStr = pw.pointee.pw_name {
            name = String(cString: cStr)
        } else {
            name = "\(uid)"
        }
        uidCache[uid] = name
        return name
    }

    private static func groupName(forGID gid: gid_t) -> String {
        if let cached = gidCache[gid] { return cached }
        let name: String
        if let gr = getgrgid(gid), let cStr = gr.pointee.gr_name {
            name = String(cString: cStr)
        } else {
            name = "\(gid)"
        }
        gidCache[gid] = name
        return name
    }
}
