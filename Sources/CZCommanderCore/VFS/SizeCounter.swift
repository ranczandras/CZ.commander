import Foundation

/// Counts files, folders and bytes of what is about to be copied / moved / deleted, in the
/// background while the confirmation dialog is open (Total Commander shows the totals there).
public final class SizeCounter: @unchecked Sendable {
    public struct Totals: Equatable, Sendable {
        public var files = 0
        public var folders = 0
        public var bytes: Int64 = 0
        public var isDone = false
        public init() {}
    }

    private let lock = NSLock()
    private var cancelled = false
    private var task: Task<Void, Never>?

    public init() {}

    public var isCancelled: Bool { lock.withLock { cancelled } }

    public func cancel() {
        lock.withLock { cancelled = true }
        task?.cancel()
    }

    /// Counts `localPaths` (links not followed) and `dropbox` items (folders walked one listing at
    /// a time). `onUpdate` is called about 8 times a second and once at the end (`isDone`).
    public func start(localPaths: [String], dropbox: [DropboxEntry] = [], client: DropboxClient = .shared,
                      onUpdate: @escaping @Sendable (Totals) -> Void) {
        task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            var totals = Totals()
            var lastEmit = Date.distantPast
            func emit(force: Bool = false) {
                let now = Date()
                guard force || now.timeIntervalSince(lastEmit) > 0.12 else { return }
                lastEmit = now
                onUpdate(totals)
            }

            for path in localPaths {
                if self.isCancelled { return }
                var st = stat()
                guard lstat(path, &st) == 0 else { continue }
                if (st.st_mode & S_IFMT) != S_IFDIR {
                    totals.files += 1
                    totals.bytes += Int64(st.st_size)
                    emit()
                    continue
                }
                totals.folders += 1
                guard let e = FileManager.default.enumerator(atPath: path) else { continue }
                var n = 0
                while let rel = e.nextObject() as? String {
                    n += 1
                    if n % 500 == 0 && self.isCancelled { return }
                    var cst = stat()
                    guard lstat((path as NSString).appendingPathComponent(rel), &cst) == 0 else { continue }
                    if (cst.st_mode & S_IFMT) == S_IFDIR {
                        totals.folders += 1
                    } else {
                        totals.files += 1
                        totals.bytes += Int64(cst.st_size)
                    }
                    emit()
                }
            }

            var queue: [DropboxLocation] = []
            for item in dropbox {
                if item.isFolder {
                    totals.folders += 1
                    queue.append(item.location)
                } else {
                    totals.files += 1
                    totals.bytes += item.size
                }
            }
            emit()
            while !queue.isEmpty {
                if self.isCancelled { return }
                let loc = queue.removeFirst()
                guard let entries = try? await client.list(loc) else { continue }
                for e in entries {
                    if e.isFolder {
                        totals.folders += 1
                        queue.append(e.location)
                    } else {
                        totals.files += 1
                        totals.bytes += e.size
                    }
                }
                emit()
            }
            totals.isDone = true
            if !self.isCancelled { emit(force: true) }
        }
    }
}
