import Foundation
import Darwin

// Copy / move with live progress (Total Commander style): current file, bytes of the current
// file and of the whole job, speed, pause and cancel. Data is copied with copyfile(3), which
// clones on APFS when it can (instant) and reports progress while it copies; folders are
// merged into existing ones, moves on the same volume are renames.

/// Pause / cancel switch shared between the UI and a running transfer.
public final class TransferControl: @unchecked Sendable {
    private let condition = NSCondition()
    private var cancelled = false
    private var paused = false
    private var stickyPolicy: OverwritePolicy?

    /// Asks the user about an existing target (set by the app; called on the transfer thread and
    /// expected to block until answered). Without it `.ask` overwrites, as before.
    public var conflictResolver: (@Sendable (TransferConflict) -> TransferConflictDecision)?

    public init() {}

    /// Decides what to do with an existing target, asking when the policy is `.ask`. "… All"
    /// answers stick for the rest of the job.
    public func decide(_ conflict: TransferConflict, policy: OverwritePolicy) -> TransferConflictAction {
        condition.lock()
        let effective = stickyPolicy ?? policy
        condition.unlock()
        switch effective {
        case .overwriteAll: return .overwrite
        case .skipAll: return .skip
        case .autoRenameSource: return .renameCopy
        case .autoRenameTarget: return .renameExisting
        case .overwriteOlder: return Self.olderAction(conflict)
        case .ask:
            guard let resolver = conflictResolver else { return .overwrite }
            let answer = resolver(conflict)
            func stick(_ p: OverwritePolicy) { condition.lock(); stickyPolicy = p; condition.unlock() }
            switch answer {
            case .overwrite: return .overwrite
            case .overwriteAll: stick(.overwriteAll); return .overwrite
            case .overwriteAllOlder: stick(.overwriteOlder); return Self.olderAction(conflict)
            case .skip: return .skip
            case .skipAll: stick(.skipAll); return .skip
            case .rename: return .renameCopy
            case .renameAll: stick(.autoRenameSource); return .renameCopy
            case .cancel: cancel(); return .cancel
            }
        }
    }

    /// Overwrite only when the source is newer than the target.
    static func olderAction(_ c: TransferConflict) -> TransferConflictAction {
        guard let s = c.sourceDate, let t = c.targetDate else { return .overwrite }
        return s > t.addingTimeInterval(1) ? .overwrite : .skip
    }

    public var isCancelled: Bool {
        condition.lock(); defer { condition.unlock() }
        return cancelled
    }

    public var isPaused: Bool {
        condition.lock(); defer { condition.unlock() }
        return paused
    }

    public func cancel() {
        condition.lock()
        cancelled = true
        paused = false
        condition.broadcast()
        condition.unlock()
    }

    public func pause() {
        condition.lock(); paused = true; condition.unlock()
    }

    public func resume() {
        condition.lock()
        paused = false
        condition.broadcast()
        condition.unlock()
    }

    /// Waits while paused. Returns false when the transfer was cancelled.
    public func checkpoint() -> Bool {
        condition.lock()
        while paused && !cancelled { condition.wait() }
        let ok = !cancelled
        condition.unlock()
        return ok
    }
}

public struct TransferCancelledError: LocalizedError, Sendable {
    public init() {}
    public var errorDescription: String? { "Cancelled." }
}

/// Speed over the last few seconds (a plain average would hide stalls and bursts).
final class TransferSpeedMeter {
    private var samples: [(time: TimeInterval, bytes: Int64)] = []
    private let window: TimeInterval

    init(window: TimeInterval = 3) { self.window = window }

    func add(bytes: Int64, at time: TimeInterval) -> Double {
        samples.append((time, bytes))
        while let first = samples.first, time - first.time > window, samples.count > 2 { samples.removeFirst() }
        guard let first = samples.first, let last = samples.last, last.time - first.time > 0.05 else { return 0 }
        return Double(last.bytes - first.bytes) / (last.time - first.time)
    }
}

/// Collects progress from the copy loop and hands it out at most ~10 times a second.
final class TransferReporter {
    let handler: ((FileOperationProgress) -> Void)?
    var progress = FileOperationProgress()
    private let start = ProcessInfo.processInfo.systemUptime
    private var lastEmit: TimeInterval = 0
    private let meter = TransferSpeedMeter()
    private var pausedTotal: TimeInterval = 0
    private var pausedSince: TimeInterval?

    init(handler: ((FileOperationProgress) -> Void)?) { self.handler = handler }

    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func notePaused(_ isPaused: Bool) {
        if isPaused, pausedSince == nil { pausedSince = now }
        if !isPaused, let since = pausedSince { pausedTotal += now - since; pausedSince = nil }
    }

    func emit(force: Bool = false) {
        guard let handler else { return }
        let t = now
        guard force || t - lastEmit >= 0.1 else { return }
        lastEmit = t
        progress.elapsedSeconds = max(0, t - start - pausedTotal)
        progress.bytesPerSecond = meter.add(bytes: progress.processedBytes, at: t)
        handler(progress)
    }
}

public enum TransferEngine {

    // copyfile.h values (defined here: several are macros Swift does not import).
    static let cfACL: UInt32 = 1 << 0
    static let cfStat: UInt32 = 1 << 1
    static let cfXattr: UInt32 = 1 << 2
    static let cfData: UInt32 = 1 << 3
    static let cfMetadata: UInt32 = cfACL | cfStat | cfXattr
    static let cfExcl: UInt32 = 1 << 17
    static let cfNoFollowSrc: UInt32 = 1 << 18
    static let cfClone: UInt32 = 1 << 24
    static let stateStatusCB: UInt32 = 6
    static let stateStatusCtx: UInt32 = 7
    static let stateCopied: UInt32 = 8
    static let stateWasCloned: UInt32 = 10
    static let whatCopyData: Int32 = 4
    static let stageProgress: Int32 = 4
    static let resultContinue: Int32 = 0
    static let resultQuit: Int32 = 2

    /// Copies or moves `sources` into `destDir`. Returns the top-level destination paths.
    @discardableResult
    public static func copyOrMove(
        sources: [String],
        to destDir: String,
        isMove: Bool,
        options: FileOperationOptions = FileOperationOptions(),
        control: TransferControl? = nil,
        progress: ((FileOperationProgress) -> Void)? = nil
    ) throws -> [String] {
        let fm = FileManager.default
        if !fm.fileExists(atPath: destDir) {
            try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        }
        let reporter = TransferReporter(handler: progress)
        let destDevice = device(of: destDir)

        // 1. Decide per top-level item: same-volume move = rename, everything else = copy.
        struct Top { let src: String; var dst: String; let rename: Bool }
        var tops: [Top] = []
        var created: [String] = []
        for src in sources {
            let name = FileSystemEngine.transformFileName((src as NSString).lastPathComponent, withMask: options.targetMask)
            var dst = (destDir as NSString).appendingPathComponent(name)
            if (src as NSString).standardizingPath == (dst as NSString).standardizingPath {
                if isMove { created.append(dst); continue }
                dst = FileSystemEngine.uniqueFilePath(for: dst)
            }
            let rename = isMove && device(of: src) == destDevice && destDevice != nil
            tops.append(Top(src: src, dst: dst, rename: rename))
        }

        // 2. Count what has to be copied (TC shows totals before it starts).
        reporter.progress.isScanning = true
        reporter.progress.totalFiles = 0
        for top in tops {
            if top.rename {
                reporter.progress.totalFiles += 1
                continue
            }
            try scan(top.src, into: reporter, control: control)
        }
        reporter.progress.isScanning = false
        reporter.emit(force: true)

        // 3. Run. A move across volumes copies everything first; the originals are removed only
        // after the whole job went through (cancel or an error leaves every source in place).
        let ledger = MoveLedger()
        for top in tops {
            reporter.progress.currentFileName = (top.src as NSString).lastPathComponent
            reporter.progress.currentSourcePath = top.src
            reporter.progress.currentDestinationPath = top.dst
            try checkpoint(control, reporter)
            if top.rename {
                if let final = try renameTop(src: top.src, dst: top.dst, options: options, reporter: reporter, reporterControl: control) {
                    created.append(final)
                }
                continue
            }
            if let final = try copyTree(src: top.src, dst: top.dst, isMove: isMove, options: options,
                                        control: control, reporter: reporter, ledger: ledger) {
                created.append(final)
            }
        }
        if isMove && (!ledger.files.isEmpty || !ledger.directories.isEmpty) {
            reporter.progress.currentFileName = "Removing the originals…"
            reporter.progress.currentSourcePath = ""
            reporter.progress.currentDestinationPath = ""
            reporter.emit(force: true)
            for file in ledger.files {
                try FileSystemEngine.removeExistingUnlockingIfNeeded(atPath: file)
            }
            // Deepest first; a folder that still holds skipped files stays.
            for dir in ledger.directories { rmdir(dir) }
        }
        reporter.progress.currentFileName = ""
        reporter.progress.currentSourcePath = ""
        reporter.progress.currentDestinationPath = ""
        reporter.emit(force: true)
        return created
    }

    // MARK: Scan

    static func scan(_ path: String, into reporter: TransferReporter, control: TransferControl?) throws {
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        if (st.st_mode & S_IFMT) != S_IFDIR {
            reporter.progress.totalFiles += 1
            reporter.progress.totalBytes += Int64(st.st_size)
            return
        }
        guard let e = FileManager.default.enumerator(atPath: path) else { return }
        var n = 0
        while let rel = e.nextObject() as? String {
            n += 1
            if n % 2000 == 0 {
                if let control, control.isCancelled { throw TransferCancelledError() }
                reporter.progress.currentFileName = rel
                reporter.emit()
            }
            var cst = stat()
            guard lstat((path as NSString).appendingPathComponent(rel), &cst) == 0 else { continue }
            if (cst.st_mode & S_IFMT) == S_IFDIR { continue }
            reporter.progress.totalFiles += 1
            reporter.progress.totalBytes += Int64(cst.st_size)
        }
    }

    // MARK: Rename (same-volume move)

    static func renameTop(src: String, dst: String, options: FileOperationOptions, reporter: TransferReporter,
                          reporterControl: TransferControl? = nil) throws -> String? {
        reporter.progress.currentFileName = (src as NSString).lastPathComponent
        reporter.progress.currentSourcePath = src
        reporter.progress.currentDestinationPath = dst
        reporter.emit()
        guard let target = try resolveConflict(src: src, dst: dst, policy: options.overwritePolicy, mergeDirectories: false,
                                               control: reporterControl) else {
            reporter.progress.processedFiles += 1
            reporter.progress.skippedFiles += 1
            return nil
        }
        try FileManager.default.moveItem(atPath: src, toPath: target)
        reporter.progress.processedFiles += 1
        reporter.emit()
        return target
    }

    // MARK: Copy

    /// Sources of a cross-volume move that were copied completely, removed at the very end.
    final class MoveLedger {
        var files: [String] = []
        /// In post-order (children before their folder).
        var directories: [String] = []
    }

    /// Copies one item (recursively). Returns its final destination path or nil when skipped.
    static func copyTree(src: String, dst: String, isMove: Bool, options: FileOperationOptions,
                         control: TransferControl?, reporter: TransferReporter,
                         ledger: MoveLedger = MoveLedger()) throws -> String? {
        // Show what comes next even while paused.
        reporter.progress.currentFileName = (src as NSString).lastPathComponent
        reporter.progress.currentSourcePath = src
        reporter.progress.currentDestinationPath = dst
        try checkpoint(control, reporter)
        var st = stat()
        guard lstat(src, &st) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "Cannot read \(src): \(String(cString: strerror(errno)))"])
        }
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR

        guard let target = try resolveConflict(src: src, dst: dst, policy: options.overwritePolicy, mergeDirectories: isDir,
                                               control: control) else {
            // Skipped: count its bytes as done so the total still reaches 100%.
            if isDir {
                let skipped = Int64(FileSystemEngine.calculateDirectorySize(at: src))
                reporter.progress.processedBytes += skipped
            } else {
                reporter.progress.processedBytes += Int64(st.st_size)
                reporter.progress.processedFiles += 1
                reporter.progress.skippedFiles += 1
            }
            return nil
        }

        if isDir {
            let fm = FileManager.default
            if !fm.fileExists(atPath: target) {
                try fm.createDirectory(atPath: target, withIntermediateDirectories: false)
            }
            let children = (try? fm.contentsOfDirectory(atPath: src))?.sorted() ?? []
            for child in children {
                _ = try copyTree(src: (src as NSString).appendingPathComponent(child),
                                 dst: (target as NSString).appendingPathComponent(child),
                                 isMove: isMove, options: options, control: control, reporter: reporter, ledger: ledger)
            }
            // Folder metadata last, so the copied children do not change its dates again.
            _ = copyfile(src, target, nil, copyfile_flags_t(cfMetadata))
            if isMove { ledger.directories.append(src) }
            return target
        }

        try copyFile(src: src, dst: target, size: Int64(st.st_size), options: options, control: control, reporter: reporter)
        if isMove { ledger.files.append(src) }
        return target
    }

    /// Applies the overwrite policy (asking the user for `.ask`) when `dst` exists. Returns where
    /// to write, or nil to skip. Folders onto folders merge (their files are checked one by one).
    static func resolveConflict(src: String, dst: String, policy: OverwritePolicy, mergeDirectories: Bool,
                                control: TransferControl? = nil) throws -> String? {
        var dstStat = stat()
        guard lstat(dst, &dstStat) == 0 else { return dst }
        let dstIsDir = (dstStat.st_mode & S_IFMT) == S_IFDIR
        if mergeDirectories && dstIsDir { return dst }
        var srcStat = stat()
        let hasSrc = lstat(src, &srcStat) == 0
        let conflict = TransferConflict(
            sourceName: (src as NSString).lastPathComponent, sourcePath: src,
            sourceSize: hasSrc ? Int64(srcStat.st_size) : nil,
            sourceDate: hasSrc ? Date(timeIntervalSince1970: TimeInterval(srcStat.st_mtimespec.tv_sec)) : nil,
            targetPath: dst, targetSize: Int64(dstStat.st_size),
            targetDate: Date(timeIntervalSince1970: TimeInterval(dstStat.st_mtimespec.tv_sec)))
        let action = (control ?? TransferControl()).decide(conflict, policy: policy)
        switch action {
        case .skip:
            return nil
        case .cancel:
            throw TransferCancelledError()
        case .renameCopy:
            return FileSystemEngine.uniqueFilePath(for: dst)
        case .renameExisting:
            try FileManager.default.moveItem(atPath: dst, toPath: FileSystemEngine.uniqueFilePath(for: dst))
            return dst
        case .overwrite:
            try FileSystemEngine.removeExistingUnlockingIfNeeded(atPath: dst)
            return dst
        }
    }

    /// Box handed to the C callback of copyfile.
    final class CopyContext {
        let control: TransferControl?
        let reporter: TransferReporter
        let base: Int64
        var cancelled = false

        init(control: TransferControl?, reporter: TransferReporter, base: Int64) {
            self.control = control
            self.reporter = reporter
            self.base = base
        }
    }

    static func copyFile(src: String, dst: String, size: Int64, options: FileOperationOptions,
                         control: TransferControl?, reporter: TransferReporter) throws {
        reporter.progress.currentFileName = (src as NSString).lastPathComponent
        reporter.progress.currentSourcePath = src
        reporter.progress.currentDestinationPath = dst
        reporter.progress.currentFileBytes = 0
        reporter.progress.currentFileTotal = size
        reporter.emit()

        let context = CopyContext(control: control, reporter: reporter, base: reporter.progress.processedBytes)
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        let callback: copyfile_callback_t = { what, stage, state, _, _, ctx in
            guard let ctx else { return TransferEngine.resultContinue }
            let box = Unmanaged<CopyContext>.fromOpaque(ctx).takeUnretainedValue()
            if what == TransferEngine.whatCopyData && stage == TransferEngine.stageProgress {
                var copied: off_t = 0
                copyfile_state_get(state, TransferEngine.stateCopied, &copied)
                box.reporter.progress.currentFileBytes = Int64(copied)
                box.reporter.progress.processedBytes = box.base + Int64(copied)
                box.reporter.emit()
            }
            if let control = box.control {
                if control.isPaused {
                    box.reporter.notePaused(true)
                    box.reporter.emit(force: true)
                }
                let ok = control.checkpoint()
                box.reporter.notePaused(false)
                if !ok {
                    box.cancelled = true
                    return TransferEngine.resultQuit
                }
            }
            return TransferEngine.resultContinue
        }
        _ = copyfile_state_set(state, stateStatusCB, unsafeBitCast(callback, to: UnsafeRawPointer.self))
        let ctxPtr = Unmanaged.passUnretained(context).toOpaque()
        _ = copyfile_state_set(state, stateStatusCtx, ctxPtr)

        let flags = copyfile_flags_t(cfClone | cfExcl | cfNoFollowSrc | cfMetadata | cfData)
        let rc = withExtendedLifetime(context) { copyfile(src, dst, state, flags) }
        if rc != 0 {
            let err = errno
            unlink(dst)  // never leave a half-written file behind
            if context.cancelled || (control?.isCancelled ?? false) { throw TransferCancelledError() }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "Copying \((src as NSString).lastPathComponent) failed: \(String(cString: strerror(err)))"])
        }

        if !options.preserveTimestamps {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dst)
        }
        if options.verifyAfterCopy {
            var checkSt = stat()
            if lstat(dst, &checkSt) == 0, (checkSt.st_mode & S_IFMT) == S_IFREG {
                reporter.progress.currentFileName = "Verifying " + (src as NSString).lastPathComponent
                reporter.emit(force: true)
                if try ChecksumEngine.crc32(ofFileAt: src) != ChecksumEngine.crc32(ofFileAt: dst) {
                    throw NSError(domain: "CZCommander.Verify", code: 500,
                                  userInfo: [NSLocalizedDescriptionKey: "CRC32 verification failed for \((src as NSString).lastPathComponent)"])
                }
            }
        }
        reporter.progress.processedBytes = context.base + size
        reporter.progress.currentFileBytes = size
        reporter.progress.processedFiles += 1
        reporter.emit()
    }

    static func checkpoint(_ control: TransferControl?, _ reporter: TransferReporter) throws {
        guard let control else { return }
        if control.isPaused {
            reporter.notePaused(true)
            reporter.emit(force: true)
        }
        let ok = control.checkpoint()
        reporter.notePaused(false)
        if !ok { throw TransferCancelledError() }
    }

    static func device(of path: String) -> dev_t? {
        var st = stat()
        return lstat(path, &st) == 0 ? st.st_dev : nil
    }
}
