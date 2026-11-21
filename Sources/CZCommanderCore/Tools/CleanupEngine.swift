import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(CleanupLinuxFTS)
import CleanupLinuxFTS   // development only: <fts.h> for building this file on Linux
#endif

// Cleanup: finds junk (Trash, caches, logs, temporary files, developer leftovers), groups it
// and deletes only what the user ticked. Which locations are scanned, and why each one is
// considered safe, is documented in docs/CLEANUP.md; the list itself lives in
// CleanupCatalog.swift. This file holds the scanner, the safety checks and the remover.
//
// Safety model (every deletion passes all of these, see `CleanupSafety`):
//   1. Allowlist: a path can only be deleted if it matches a catalog rule's pattern.
//   2. Denylist: protected folders (home, Documents, Keychains, iCloud Drive, /System …)
//      are refused even if a rule would match.
//   3. Symlinks are never followed: a link is removed as a link, and a location that
//      resolves into a protected folder is refused.
//   4. Traversal never crosses onto another mounted volume.

// MARK: - Model

public enum CleanupCategory: String, CaseIterable, Sendable, Identifiable {
    case trash
    case appCaches
    case browserCaches
    case logs
    case tempFiles
    case xcode
    case devTools
    case appData
    case largeLeftovers

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .trash: return "Trash"
        case .appCaches: return "Application caches"
        case .browserCaches: return "Browser caches"
        case .logs: return "Logs & crash reports"
        case .tempFiles: return "Temporary files"
        case .xcode: return "Xcode & simulators"
        case .devTools: return "Developer tool caches"
        case .appData: return "App leftovers (chat, media, editors)"
        case .largeLeftovers: return "Large leftovers (review first)"
        }
    }

    public var symbolName: String {
        switch self {
        case .trash: return "trash"
        case .appCaches: return "square.stack.3d.up"
        case .browserCaches: return "globe"
        case .logs: return "doc.text.magnifyingglass"
        case .tempFiles: return "clock.arrow.circlepath"
        case .xcode: return "hammer"
        case .devTools: return "shippingbox"
        case .appData: return "bubble.left.and.bubble.right"
        case .largeLeftovers: return "externaldrive.badge.exclamationmark"
        }
    }
}

public enum CleanupRisk: String, Sendable {
    /// Regenerated or re-downloaded on demand. Ticked by default.
    case safe
    /// Deleting costs something (a long re-download, a rebuild, data that is not regenerated).
    /// Never ticked by default.
    case caution
}

public enum CleanupTarget: Sendable, Hashable {
    /// Every direct child of each folder matching the pattern is one deletable item.
    case contents(String)
    /// Each path matching the pattern is one deletable item.
    case item(String)
}

public struct CleanupRule: Identifiable, Sendable {
    public let id: String
    public let category: CleanupCategory
    public let title: String
    /// What the files are and what deleting them costs. Shown next to the group.
    public let detail: String
    public let risk: CleanupRisk
    public let targets: [CleanupTarget]
    /// Skip items modified within the last N days (0 = no age limit).
    public let minAgeDays: Int
    /// Apps that own these files. Items of a running app are not ticked by default.
    public let bundleIDs: [String]
    /// Child names never listed (compared case-insensitively).
    public let excludedNames: Set<String>
    /// Children whose name starts with one of these are never listed (case-insensitive).
    public let excludedPrefixes: [String]
    /// Children whose name contains one of these are never listed (case-insensitive).
    public let excludedSubstrings: [String]
    /// If not empty, only children with one of these extensions are listed (lowercase, no dot).
    public let allowedExtensions: Set<String>
    /// Empty the folder but keep the folder itself (for `.item` targets).
    public let keepRoot: Bool
    /// List items even if they take no space (Trash: everything in it must go).
    public let listEmptyItems: Bool

    public init(
        id: String,
        category: CleanupCategory,
        title: String,
        detail: String,
        risk: CleanupRisk = .safe,
        targets: [CleanupTarget],
        minAgeDays: Int = 0,
        bundleIDs: [String] = [],
        excludedNames: Set<String> = [],
        excludedPrefixes: [String] = [],
        excludedSubstrings: [String] = [],
        allowedExtensions: Set<String> = [],
        keepRoot: Bool = false,
        listEmptyItems: Bool = false
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.detail = detail
        self.risk = risk
        self.targets = targets
        self.minAgeDays = minAgeDays
        self.bundleIDs = bundleIDs
        self.excludedNames = Set(excludedNames.map { $0.lowercased() })
        self.excludedPrefixes = excludedPrefixes.map { $0.lowercased() }
        self.excludedSubstrings = excludedSubstrings.map { $0.lowercased() }
        self.allowedExtensions = Set(allowedExtensions.map { $0.lowercased() })
        self.keepRoot = keepRoot
        self.listEmptyItems = listEmptyItems
    }

    /// Exclusions only (also applied to whatever a `*` in an `.item` pattern matched).
    func allowsName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if excludedNames.contains(lower) { return false }
        if excludedPrefixes.contains(where: { lower.hasPrefix($0) }) { return false }
        if excludedSubstrings.contains(where: { lower.contains($0) }) { return false }
        return true
    }

    func allowsChildName(_ name: String) -> Bool {
        guard allowsName(name) else { return false }
        let lower = name.lowercased()
        if !allowedExtensions.isEmpty {
            let ext = (lower as NSString).pathExtension
            if !allowedExtensions.contains(ext) { return false }
        }
        return true
    }

    /// Allowlist check: is `path` something this rule may list and delete?
    public func matches(path: String) -> Bool {
        for target in targets {
            switch target {
            case .contents(let pattern):
                let name = (path as NSString).lastPathComponent
                if CleanupPath.matches(pattern: pattern + "/*", path: path), allowsChildName(name) { return true }
            case .item(let pattern):
                guard CleanupPath.matches(pattern: pattern, path: path) else { continue }
                let wildcardParts = zip(CleanupPath.components(pattern), CleanupPath.components(path))
                    .filter { $0.0.contains("*") }.map { $0.1 }
                if wildcardParts.allSatisfy(allowsName) { return true }
            }
        }
        return false
    }
}

public struct CleanupItem: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let displayName: String
    public let ruleID: String
    public let category: CleanupCategory
    /// Space the item occupies on disk (allocated blocks; hard links counted once).
    public let sizeBytes: Int64
    /// Sum of the file lengths.
    public let logicalBytes: Int64
    public let fileCount: Int
    public let newestModification: Date?
    public let isDirectory: Bool
    /// The app that owns the item is running right now.
    public let ownerRunning: Bool
    /// Ticked when the results first appear.
    public let preselected: Bool
}

public struct CleanupGroupResult: Identifiable, Sendable {
    public var id: String { rule.id }
    public let rule: CleanupRule
    public let items: [CleanupItem]
    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }
}

public struct CleanupCategoryResult: Identifiable, Sendable {
    public var id: String { category.id }
    public let category: CleanupCategory
    public let groups: [CleanupGroupResult]
    public var totalBytes: Int64 { groups.reduce(0) { $0 + $1.totalBytes } }
    public var itemCount: Int { groups.reduce(0) { $0 + $1.items.count } }
}

public struct CleanupScanResult: Sendable {
    public let categories: [CleanupCategoryResult]
    /// Locations that exist but could not be read (usually: Full Disk Access is missing).
    public let unreadableLocations: [String]
    public let wasCancelled: Bool
    public var totalBytes: Int64 { categories.reduce(0) { $0 + $1.totalBytes } }
    public var allItems: [CleanupItem] { categories.flatMap { $0.groups.flatMap { $0.items } } }

    public init(categories: [CleanupCategoryResult], unreadableLocations: [String], wasCancelled: Bool) {
        self.categories = categories
        self.unreadableLocations = unreadableLocations
        self.wasCancelled = wasCancelled
    }
}

public struct CleanupProgress: Sendable {
    public let stepTitle: String
    public let currentPath: String
    public let completedSteps: Int
    public let totalSteps: Int
    public let bytesSoFar: Int64
    public let itemsSoFar: Int
}

public struct CleanupFailure: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let reason: String
}

public struct CleanupDeleteReport: Sendable {
    public var freedBytes: Int64 = 0
    /// Items that are completely gone.
    public var deletedPaths: [String] = []
    public var failures: [CleanupFailure] = []
    public var wasCancelled: Bool = false
    public init() {}
}

public struct TrashSummary: Sendable {
    public let itemCount: Int
    public let sizeBytes: Int64
    /// `~/.Trash` exists but macOS did not let us read it (no Full Disk Access).
    public let homeTrashUnreadable: Bool
    public let items: [CleanupItem]
}

/// Thread-safe cancel flag shared between the UI and a running scan / delete.
public final class CleanupCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Where things live for the current user. Injected so tests can run against a sandbox folder.
public struct CleanupEnvironment: Sendable {
    public var home: String
    /// Per-user temporary folder (`$TMPDIR`, `/private/var/folders/xx/yy/T`).
    public var tempDirectory: String
    /// Prefix for system paths (`""` on a real Mac, a sandbox folder in tests).
    public var systemRoot: String
    public var userID: UInt32
    public var now: Date
    /// Lowercased bundle identifiers of the running apps.
    public var runningBundleIDs: Set<String>

    public init(
        home: String,
        tempDirectory: String,
        systemRoot: String = "",
        userID: UInt32 = getuid(),
        now: Date = Date(),
        runningBundleIDs: Set<String> = []
    ) {
        self.home = CleanupPath.normalize(home)
        self.tempDirectory = CleanupPath.normalize(tempDirectory)
        self.systemRoot = systemRoot.isEmpty ? "" : CleanupPath.normalize(systemRoot)
        self.userID = userID
        self.now = now
        self.runningBundleIDs = Set(runningBundleIDs.map { $0.lowercased() })
    }

    public static func current(runningBundleIDs: Set<String> = []) -> CleanupEnvironment {
        CleanupEnvironment(
            home: FileManager.default.homeDirectoryForCurrentUser.path,
            tempDirectory: NSTemporaryDirectory(),
            runningBundleIDs: runningBundleIDs
        )
    }

    public func homePath(_ relative: String) -> String { home + "/" + relative }
    public func systemPath(_ absolute: String) -> String { systemRoot + absolute }
}

// MARK: - Paths and patterns

public enum CleanupPath {
    /// Lexical clean-up only: collapses `//`, drops a trailing `/`. Never resolves symlinks.
    public static func normalize(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        return "/" + parts.joined(separator: "/")
    }

    public static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// `true` if `path` is clean: absolute, normalized, without `.` or `..` parts.
    public static func isCanonicalForm(_ path: String) -> Bool {
        guard path.hasPrefix("/"), normalize(path) == path else { return false }
        return !components(path).contains(where: { $0 == "." || $0 == ".." })
    }

    /// `*` matches any run of characters inside one path component.
    public static func wildcardMatch(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern.unicodeScalars), t = Array(text.unicodeScalars)
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "*" {
                star = pi; mark = ti; pi += 1
            } else if pi < p.count, p[pi] == t[ti] {
                pi += 1; ti += 1
            } else if star >= 0 {
                pi = star + 1; mark += 1; ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// Component-wise match: the path must have exactly as many components as the pattern.
    public static func matches(pattern: String, path: String) -> Bool {
        let pc = components(pattern), tc = components(path)
        guard pc.count == tc.count, !pc.isEmpty else { return false }
        for (p, t) in zip(pc, tc) {
            if p.contains("*") {
                if !wildcardMatch(p, t) { return false }
            } else if p != t {
                return false
            }
        }
        return true
    }

    /// Existing paths matching the pattern. A wildcard component that is followed by more
    /// components only descends into real folders, never through a symlink.
    public static func expand(pattern: String) -> [String] {
        var current: [String] = [""]
        let parts = components(pattern)
        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            var next: [String] = []
            for base in current {
                if part.contains("*") {
                    let dir = base.isEmpty ? "/" : base
                    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
                    for name in names.sorted() where wildcardMatch(part, name) {
                        let candidate = base + "/" + name
                        if isLast || CleanupFS.isRealDirectory(candidate) { next.append(candidate) }
                    }
                } else {
                    let candidate = base + "/" + part
                    if CleanupFS.exists(candidate) { next.append(candidate) }
                }
            }
            current = next
            if current.isEmpty { break }
        }
        return current
    }

    public static func isInside(_ path: String, of ancestor: String) -> Bool {
        path.hasPrefix(ancestor == "/" ? "/" : ancestor + "/")
    }
}

// MARK: - Low level file system helpers

struct CleanupFileKey: Hashable {
    let device: UInt64
    let inode: UInt64
}

struct CleanupTreeStats {
    var allocated: Int64 = 0
    var logical: Int64 = 0
    var files: Int = 0
    var newest: Int = 0
    /// Sockets, FIFOs or device nodes: the tree is in use by a running process.
    var hasSpecialFiles = false
    var hasUnreadableParts = false
}

enum CleanupFS {
    static func lstatInfo(_ path: String) -> stat? {
        var st = stat()
        return lstat(path, &st) == 0 ? st : nil
    }

    static func exists(_ path: String) -> Bool { lstatInfo(path) != nil }

    static func isRealDirectory(_ path: String) -> Bool {
        guard let st = lstatInfo(path) else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    static func modificationSeconds(_ st: stat) -> Int {
        #if canImport(Darwin)
        return Int(st.st_mtimespec.tv_sec)
        #else
        return Int(st.st_mtim.tv_sec)
        #endif
    }

    static func key(_ st: stat) -> CleanupFileKey {
        CleanupFileKey(device: UInt64(truncatingIfNeeded: st.st_dev), inode: UInt64(truncatingIfNeeded: st.st_ino))
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func errorText(_ code: Int32) -> String {
        switch code {
        case EPERM: return "Operation not permitted (protected by macOS, or Full Disk Access is missing)"
        case EACCES: return "Permission denied"
        case EBUSY: return "In use"
        case ENOTEMPTY: return "Folder is not empty (some files inside could not be removed)"
        default: return String(cString: strerror(code))
        }
    }

    /// Walks a tree without following symlinks and without leaving its volume.
    static func walk(_ path: String, _ visit: (_ info: Int32, _ entryPath: UnsafePointer<CChar>, _ st: stat?, _ level: Int, _ errno: Int32) -> Bool) {
        guard let cPath = strdup(path) else { return }
        defer { free(cPath) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
        defer { fts_close(fts) }
        while let entry = fts_read(fts) {
            let info = Int32(entry.pointee.fts_info)
            let st: stat? = (info == FTS_NS || info == FTS_NSOK) ? nil : entry.pointee.fts_statp?.pointee
            guard let entryPath = entry.pointee.fts_path else { continue }
            if !visit(info, entryPath, st, Int(entry.pointee.fts_level), entry.pointee.fts_errno) { break }
        }
    }

    static func measure(_ path: String, seen: inout Set<CleanupFileKey>, cancellation: CleanupCancellation?) -> CleanupTreeStats {
        var stats = CleanupTreeStats()
        var counter = 0
        walk(path) { info, _, st, _, _ in
            counter += 1
            if counter % 512 == 0, cancellation?.isCancelled == true { return false }
            switch info {
            case FTS_F, FTS_SL, FTS_SLNONE:
                guard let st else { return true }
                stats.files += 1
                stats.newest = max(stats.newest, modificationSeconds(st))
                if st.st_nlink > 1, !seen.insert(key(st)).inserted { return true }
                stats.allocated += Int64(st.st_blocks) * 512
                stats.logical += Int64(st.st_size)
            case FTS_D:
                if let st { stats.newest = max(stats.newest, modificationSeconds(st)) }
            case FTS_DEFAULT:
                stats.hasSpecialFiles = true
            case FTS_DNR, FTS_ERR, FTS_NS:
                stats.hasUnreadableParts = true
            default:
                break
            }
            return true
        }
        return stats
    }

    struct RemoveOutcome {
        var freed: Int64 = 0
        var firstError: String? = nil
        var complete: Bool { firstError == nil }
    }

    #if canImport(Darwin)
    private static func clearLockFlags(_ path: UnsafePointer<CChar>, _ st: stat?) {
        guard let st, st.st_flags & UInt32(UF_IMMUTABLE | UF_APPEND) != 0 else { return }
        _ = lchflags(path, st.st_flags & ~UInt32(UF_IMMUTABLE | UF_APPEND))
    }
    #else
    private static func clearLockFlags(_ path: UnsafePointer<CChar>, _ st: stat?) {}
    #endif

    /// Removes a file, a symlink (the link, never its target) or a whole folder tree.
    /// Keeps going after errors so one locked file does not block the rest.
    static func removeTree(_ path: String, keepRoot: Bool, seen: inout Set<CleanupFileKey>, cancellation: CleanupCancellation?) -> RemoveOutcome {
        var outcome = RemoveOutcome()
        func fail(_ entryPath: UnsafePointer<CChar>, _ code: Int32) {
            if outcome.firstError == nil {
                outcome.firstError = "\(String(cString: entryPath)): \(errorText(code))"
            }
        }
        var counter = 0
        walk(path) { info, entryPath, st, level, ftsErrno in
            counter += 1
            if counter % 256 == 0, cancellation?.isCancelled == true {
                if outcome.firstError == nil { outcome.firstError = "Cancelled" }
                return false
            }
            switch info {
            case FTS_D:
                // Unlock the folder and make sure we may list and modify it (Go's module cache is read-only).
                clearLockFlags(entryPath, st)
                if let st, st.st_mode & 0o700 != 0o700 { _ = chmod(entryPath, (st.st_mode & 0o7777) | 0o700) }
            case FTS_DP:
                if level == 0 && keepRoot { return true }
                if rmdir(entryPath) != 0 { fail(entryPath, errno) }
            case FTS_DNR, FTS_ERR:
                fail(entryPath, ftsErrno)
            default:
                // Files, symlinks, sockets and anything fts could not stat.
                if level == 0 && keepRoot { return true }
                var result = unlink(entryPath)
                if result != 0, errno == EPERM {
                    clearLockFlags(entryPath, st)
                    result = unlink(entryPath)
                }
                if result != 0 {
                    fail(entryPath, errno)
                } else if let st, (st.st_mode & S_IFMT) == S_IFREG {
                    if st.st_nlink <= 1 || seen.insert(key(st)).inserted {
                        outcome.freed += Int64(st.st_blocks) * 512
                    }
                }
            }
            return true
        }
        return outcome
    }
}

// MARK: - Safety

public struct CleanupSafety: Sendable {
    public let environment: CleanupEnvironment
    /// Folders that may never be deleted themselves (their contents may still hold junk).
    public let protectedExact: Set<String>
    /// Folders in which nothing is ever deleted.
    public let protectedTrees: [String]

    public init(environment env: CleanupEnvironment) {
        self.environment = env
        let home = env.home
        var exact: Set<String> = [home]
        for rel in [
            "Library", "Library/Caches", "Library/Logs", "Library/Application Support",
            "Library/Containers", "Library/Group Containers", "Library/Developer",
            "Library/Developer/Xcode", "Library/Developer/CoreSimulator",
            "Downloads", "Movies", "Music", "Applications", "Public", ".Trash",
            "Library/Application Support/MobileSync"
        ] {
            exact.insert(home + "/" + rel)
        }
        for abs in [
            "/Applications", "/Library", "/Library/Caches", "/Library/Logs", "/Users", "/Volumes",
            "/private", "/private/var", "/private/tmp", "/private/var/tmp", "/private/var/folders",
            "/private/var/log", "/var", "/tmp", "/etc", "/opt", "/cores"
        ] {
            exact.insert(env.systemPath(abs))
        }
        self.protectedExact = Set(exact.map { $0.lowercased() })

        var trees: [String] = []
        for rel in [
            "Documents", "Desktop", "Pictures",
            "Library/Mobile Documents", "Library/CloudStorage", "Library/Keychains", "Library/Preferences",
            "Library/Mail", "Library/Messages", "Library/Safari", "Library/Cookies", "Library/Calendars",
            "Library/Accounts", "Library/Photos", "Library/Passes", "Library/Reminders",
            "Library/Group Containers", "Library/Application Support/AddressBook",
            "Library/Application Support/CloudDocs", "Library/Application Support/com.apple.TCC",
            "Library/Application Support/CZ.commander",
            ".ssh", ".gnupg", ".config", ".aws", ".kube"
        ] {
            trees.append(home + "/" + rel)
        }
        for abs in [
            "/System", "/usr", "/bin", "/sbin", "/private/etc", "/etc",
            "/private/var/db", "/var/db", "/private/var/vm", "/var/vm", "/private/var/root",
            "/Library/Keychains", "/Library/Preferences", "/Library/Application Support"
        ] {
            trees.append(env.systemPath(abs))
        }
        self.protectedTrees = trees.map { $0.lowercased() }
    }

    /// Case-insensitive, like the default APFS volume.
    func isProtected(_ original: String) -> Bool {
        let path = original.lowercased()
        if protectedExact.contains(path) { return true }
        // Any ancestor of the home folder (and the volume root).
        if path == "/" || CleanupPath.isInside(environment.home.lowercased(), of: path) { return true }
        return protectedTrees.contains { path == $0 || CleanupPath.isInside(path, of: $0) }
    }

    /// `nil` if the item may be deleted, otherwise the reason it is refused.
    public func refusalReason(path: String, rule: CleanupRule) -> String? {
        guard CleanupPath.isCanonicalForm(path) else { return "Not a clean absolute path" }
        guard CleanupPath.components(path).count >= 3 else { return "Too close to the volume root" }
        guard rule.matches(path: path) else { return "Not a known cleanup location" }
        if isProtected(path) { return "Protected location" }
        // Where does the containing folder really live? Refuse if a symlink redirects it
        // into a protected area.
        let parent = (path as NSString).deletingLastPathComponent
        if let realParent = CleanupFS.realPath(parent), realParent != parent {
            let real = realParent + "/" + (path as NSString).lastPathComponent
            if isProtected(real) || (protectedExact.contains(realParent.lowercased()) && !rule.matches(path: real)) {
                return "Resolves into a protected location"
            }
        }
        return nil
    }
}

// MARK: - Engine

public enum CleanupEngine {

    public static func rule(withID id: String, in rules: [CleanupRule]) -> CleanupRule? {
        rules.first { $0.id == id }
    }

    /// Scans every rule and returns the findings grouped by category. Read-only.
    public static func scan(
        environment env: CleanupEnvironment,
        rules: [CleanupRule]? = nil,
        cancellation: CleanupCancellation? = nil,
        progress: (@Sendable (CleanupProgress) -> Void)? = nil
    ) -> CleanupScanResult {
        let rules = rules ?? CleanupCatalog.rules(for: env)
        let safety = CleanupSafety(environment: env)
        var seen = Set<CleanupFileKey>()
        var claimed = Set<String>()
        var unreadable: [String] = []
        var groups: [(CleanupRule, [CleanupItem])] = []
        var bytesSoFar: Int64 = 0
        var itemsSoFar = 0
        var cancelled = false

        // A generic rule (all of ~/Library/Caches) must not list a folder that another rule
        // targets, or that contains another rule's target: that folder is shown there instead.
        let allPatterns: [(ruleID: String, parts: [String])] = rules.flatMap { rule in
            rule.targets.map { target -> (ruleID: String, parts: [String]) in
                switch target {
                case .item(let pattern), .contents(let pattern):
                    return (rule.id, CleanupPath.components(pattern))
                }
            }
        }
        func belongsToAnotherRule(_ path: String, own rule: CleanupRule) -> Bool {
            let depth = CleanupPath.components(path).count
            return allPatterns.contains { entry in
                entry.ruleID != rule.id && entry.parts.count >= depth
                    && CleanupPath.matches(pattern: "/" + entry.parts.prefix(depth).joined(separator: "/"), path: path)
            }
        }

        for (index, rule) in rules.enumerated() {
            if cancellation?.isCancelled == true { cancelled = true; break }
            var candidates: [String] = []
            for target in rule.targets {
                switch target {
                case .item(let pattern):
                    candidates += CleanupPath.expand(pattern: pattern)
                case .contents(let pattern):
                    for dir in CleanupPath.expand(pattern: pattern) {
                        do {
                            let names = try FileManager.default.contentsOfDirectory(atPath: dir)
                            for name in names.sorted() where rule.allowsChildName(name) {
                                let child = dir + "/" + name
                                if !belongsToAnotherRule(child, own: rule) { candidates.append(child) }
                            }
                        } catch {
                            if CleanupFS.exists(dir) { unreadable.append(dir) }
                        }
                    }
                }
            }

            var items: [CleanupItem] = []
            for path in candidates {
                if cancellation?.isCancelled == true { cancelled = true; break }
                guard !claimed.contains(path) else { continue }
                guard safety.refusalReason(path: path, rule: rule) == nil else { continue }
                guard let st = CleanupFS.lstatInfo(path) else { continue }
                progress?(CleanupProgress(stepTitle: rule.title, currentPath: path, completedSteps: index,
                                          totalSteps: rules.count, bytesSoFar: bytesSoFar, itemsSoFar: itemsSoFar))

                let stats = CleanupFS.measure(path, seen: &seen, cancellation: cancellation)
                if cancellation?.isCancelled == true { cancelled = true; break }
                // In use by a running process (sockets, pipes): leave it alone.
                if stats.hasSpecialFiles { continue }
                let isDirectory = (st.st_mode & S_IFMT) == S_IFDIR
                // Outside the Trash a symlink is never junk by itself, and is never followed.
                if (st.st_mode & S_IFMT) == S_IFLNK && rule.category != .trash { continue }
                if rule.keepRoot && isDirectory && stats.files == 0 { continue }
                if !rule.listEmptyItems && stats.allocated == 0 { continue }
                let newest = max(stats.newest, CleanupFS.modificationSeconds(st))
                if rule.minAgeDays > 0 {
                    let cutoff = Int(env.now.timeIntervalSince1970) - rule.minAgeDays * 86_400
                    if newest > cutoff { continue }
                }
                if isDirectory && stats.hasUnreadableParts && stats.files == 0 {
                    unreadable.append(path)
                    continue
                }

                let running = !env.runningBundleIDs.isDisjoint(with: rule.bundleIDs.map { $0.lowercased() })
                    || CleanupPath.components(path).contains { env.runningBundleIDs.contains($0.lowercased()) }
                items.append(CleanupItem(
                    path: path,
                    displayName: displayName(for: path, rule: rule),
                    ruleID: rule.id,
                    category: rule.category,
                    sizeBytes: stats.allocated,
                    logicalBytes: stats.logical,
                    fileCount: stats.files,
                    newestModification: newest > 0 ? Date(timeIntervalSince1970: TimeInterval(newest)) : nil,
                    isDirectory: isDirectory,
                    ownerRunning: running,
                    preselected: rule.risk == .safe && !running
                ))
                claimed.insert(path)
                bytesSoFar += stats.allocated
                itemsSoFar += 1
            }
            if !items.isEmpty {
                items.sort { $0.sizeBytes != $1.sizeBytes ? $0.sizeBytes > $1.sizeBytes : $0.displayName < $1.displayName }
                groups.append((rule, items))
            }
            if cancelled { break }
        }

        let categories: [CleanupCategoryResult] = CleanupCategory.allCases.compactMap { category in
            let own = groups.filter { $0.0.category == category }
                .map { CleanupGroupResult(rule: $0.0, items: $0.1) }
                .sorted { $0.totalBytes > $1.totalBytes }
            return own.isEmpty ? nil : CleanupCategoryResult(category: category, groups: own)
        }
        progress?(CleanupProgress(stepTitle: "Done", currentPath: "", completedSteps: rules.count,
                                  totalSteps: rules.count, bytesSoFar: bytesSoFar, itemsSoFar: itemsSoFar))
        var seenLocations = Set<String>()
        let uniqueUnreadable = unreadable.filter { seenLocations.insert($0).inserted }
        return CleanupScanResult(categories: categories, unreadableLocations: uniqueUnreadable, wasCancelled: cancelled)
    }

    /// Wildcard targets list items like `…/Containers/<app>/Data/Library/Caches`: show the part
    /// that tells them apart instead of the same last component for every row.
    static func displayName(for path: String, rule: CleanupRule) -> String {
        let parts = CleanupPath.components(path)
        for target in rule.targets {
            guard case .item(let pattern) = target, CleanupPath.matches(pattern: pattern, path: path) else { continue }
            let patternParts = CleanupPath.components(pattern)
            guard let wildcard = patternParts.firstIndex(where: { $0.contains("*") }) else { break }
            if wildcard == patternParts.count - 1 { break }
            let tail = parts[(wildcard + 1)...].filter { !["Data", "Library"].contains($0) }
            return parts[wildcard] + " – " + tail.joined(separator: "/")
        }
        return parts.last ?? path
    }

    /// Deletes the given items. Every item is checked against the safety rules again
    /// right before it is removed; anything that fails the check is reported, not deleted.
    public static func delete(
        items: [CleanupItem],
        environment env: CleanupEnvironment,
        rules: [CleanupRule]? = nil,
        moveToTrash: Bool = false,
        cancellation: CleanupCancellation? = nil,
        progress: (@Sendable (CleanupProgress) -> Void)? = nil
    ) -> CleanupDeleteReport {
        let rules = rules ?? CleanupCatalog.rules(for: env)
        let safety = CleanupSafety(environment: env)
        var report = CleanupDeleteReport()
        var seen = Set<CleanupFileKey>()

        for (index, item) in items.enumerated() {
            if cancellation?.isCancelled == true { report.wasCancelled = true; break }
            progress?(CleanupProgress(stepTitle: item.displayName, currentPath: item.path, completedSteps: index,
                                      totalSteps: items.count, bytesSoFar: report.freedBytes, itemsSoFar: report.deletedPaths.count))
            guard let rule = rule(withID: item.ruleID, in: rules) else {
                report.failures.append(CleanupFailure(path: item.path, reason: "Unknown cleanup rule"))
                continue
            }
            if let reason = safety.refusalReason(path: item.path, rule: rule) {
                report.failures.append(CleanupFailure(path: item.path, reason: "Refused: \(reason)"))
                continue
            }
            guard CleanupFS.exists(item.path) else {
                report.deletedPaths.append(item.path)   // already gone
                continue
            }

            if moveToTrash && rule.category != .trash {
                if let error = moveItemToTrash(item, keepRoot: rule.keepRoot) {
                    report.failures.append(CleanupFailure(path: item.path, reason: error))
                } else {
                    report.deletedPaths.append(item.path)
                }
                continue
            }

            let outcome = CleanupFS.removeTree(item.path, keepRoot: rule.keepRoot, seen: &seen, cancellation: cancellation)
            report.freedBytes += outcome.freed
            if let error = outcome.firstError {
                report.failures.append(CleanupFailure(path: item.path, reason: error))
                if error == "Cancelled" { report.wasCancelled = true; break }
            } else {
                report.deletedPaths.append(item.path)
            }
        }
        progress?(CleanupProgress(stepTitle: "Done", currentPath: "", completedSteps: items.count,
                                  totalSteps: items.count, bytesSoFar: report.freedBytes, itemsSoFar: report.deletedPaths.count))
        return report
    }

    private static func moveItemToTrash(_ item: CleanupItem, keepRoot: Bool) -> String? {
        #if canImport(Darwin)
        let fm = FileManager.default
        do {
            if keepRoot, item.isDirectory {
                for name in try fm.contentsOfDirectory(atPath: item.path) {
                    try fm.trashItem(at: URL(fileURLWithPath: item.path + "/" + name), resultingItemURL: nil)
                }
            } else {
                try fm.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
        #else
        return "Moving to the Trash is only available on macOS"
        #endif
    }

    // MARK: Trash

    public static func trashSummary(environment env: CleanupEnvironment, cancellation: CleanupCancellation? = nil) -> TrashSummary {
        let rules = CleanupCatalog.trashRules(for: env)
        let result = scan(environment: env, rules: rules, cancellation: cancellation)
        let items = result.allItems
        let homeTrash = env.homePath(".Trash")
        return TrashSummary(
            itemCount: items.count,
            sizeBytes: items.reduce(0) { $0 + $1.sizeBytes },
            homeTrashUnreadable: result.unreadableLocations.contains(homeTrash),
            items: items
        )
    }

    /// Permanently deletes everything in the user's Trash folders (home and external volumes).
    public static func emptyTrash(
        environment env: CleanupEnvironment,
        cancellation: CleanupCancellation? = nil,
        progress: (@Sendable (CleanupProgress) -> Void)? = nil
    ) -> CleanupDeleteReport {
        let rules = CleanupCatalog.trashRules(for: env)
        let items = scan(environment: env, rules: rules, cancellation: cancellation).allItems
        return delete(items: items, environment: env, rules: rules, cancellation: cancellation, progress: progress)
    }

    /// Asks Finder to empty the Trash. Used when macOS does not let the app read `~/.Trash`
    /// (no Full Disk Access). macOS asks once for permission to control Finder.
    public static func emptyTrashViaFinder() -> String? {
        #if canImport(Darwin)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"Finder\" to empty trash"]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return error.localizedDescription
        }
        if process.terminationStatus == 0 { return nil }
        let text = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Finder could not empty the Trash" : text.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        return "Only available on macOS"
        #endif
    }
}
