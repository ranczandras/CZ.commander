import Foundation
import Security

// App Uninstaller: lists installed apps and, for one app, finds everything it left in the
// Library folders (support files, caches, preferences, containers, launch agents, saved
// state, web data, logs, crash reports, privileged helpers).
//
// Search is shallow and name-based: only the direct children of well-known Library folders
// are compared with the app's bundle identifiers (its own and those of the helpers, XPC
// services and extensions inside it), its name and its executable name. Nothing is ever
// matched by a deep content search, and symlinks are never followed.

public struct InstalledApp: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let bundleID: String?
    public let version: String?
    public let executableName: String?
    public let isAppStore: Bool

    /// Why this app cannot be uninstalled here (Apple system app, CZ.commander itself), or nil.
    public var protectionReason: String? {
        AppUninstallEngine.protectionReason(path: path, bundleID: bundleID)
    }
}

public enum AppLeftoverMatch: String, Sendable {
    /// Exactly the app's (or its own helper's) bundle id.
    case bundleID
    /// Exact app / executable name.
    case name
    /// Only the start of the id matches, or the id belongs to a shared component bundled in
    /// the app (an updater used by the vendor's other apps too): listed, never preselected.
    case related
    /// Group container that only shares the vendor's team id.
    case team
}

public struct AppLeftover: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let category: String
    public let match: AppLeftoverMatch
    public var sizeBytes: Int64
    /// Ticked by default (bundle id / exact name matches). Team-wide group containers may be
    /// shared with the vendor's other apps and are never preselected.
    public let preselected: Bool
    /// Outside the home folder: macOS asks for an administrator password when it is moved.
    public let needsAdmin: Bool
    /// Launch agent / daemon label, so it can be unloaded after removal.
    public let launchLabel: String?
}

public struct AppUninstallPlan: Sendable {
    public let app: InstalledApp
    public let bundleSize: Int64
    public let relatedBundleIDs: [String]
    public let teamID: String?
    public let leftovers: [AppLeftover]

    public var leftoverBytes: Int64 { leftovers.reduce(0) { $0 + $1.sizeBytes } }
}

public enum AppUninstallEngine {

    // MARK: Apps

    public static func defaultApplicationFolders(home: String = NSHomeDirectory()) -> [String] {
        ["/Applications", home + "/Applications"]
    }

    /// Apps in the given folders, one level of sub-folders included ("/Applications/Utilities",
    /// vendor folders like "/Applications/Adobe Photoshop 2025"). Sorted by name.
    public static func listApps(in folders: [String] = defaultApplicationFolders()) -> [InstalledApp] {
        let fm = FileManager.default
        var result: [InstalledApp] = []
        var seen = Set<String>()

        func add(_ path: String) {
            guard seen.insert(path).inserted, let app = loadApp(at: path) else { return }
            result.append(app)
        }

        for folder in folders {
            guard let children = try? fm.contentsOfDirectory(atPath: folder) else { continue }
            for child in children where !child.hasPrefix(".") {
                let path = (folder as NSString).appendingPathComponent(child)
                if isSymlink(path) { continue }
                if child.lowercased().hasSuffix(".app") {
                    add(path)
                } else if isDirectory(path), let sub = try? fm.contentsOfDirectory(atPath: path) {
                    for s in sub where s.lowercased().hasSuffix(".app") {
                        let p = (path as NSString).appendingPathComponent(s)
                        if !isSymlink(p) { add(p) }
                    }
                }
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func loadApp(at path: String) -> InstalledApp? {
        let plistPath = (path as NSString).appendingPathComponent("Contents/Info.plist")
        let info = NSDictionary(contentsOfFile: plistPath) as? [String: Any] ?? [:]
        let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let displayName = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
        let name = (displayName?.isEmpty == false && displayName!.count >= fileName.count) ? displayName! : fileName
        let version = (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String)
        let masReceipt = (path as NSString).appendingPathComponent("Contents/_MASReceipt/receipt")
        return InstalledApp(
            path: path,
            name: name,
            bundleID: info["CFBundleIdentifier"] as? String,
            version: version,
            executableName: info["CFBundleExecutable"] as? String,
            isAppStore: FileManager.default.fileExists(atPath: masReceipt))
    }

    /// The vendor's own uninstaller next to the app ("Uninstall Adobe Premiere Pro 2026",
    /// "Foo Uninstaller.app") when the app sits in its own folder. Vendors like Adobe also
    /// deregister licences and shared components, which a plain removal cannot do.
    public static func vendorUninstaller(for appPath: String) -> String? {
        let folder = (appPath as NSString).deletingLastPathComponent
        guard folder != "/Applications", !folder.hasSuffix("/Applications"),
              let children = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return nil }
        let own = (appPath as NSString).lastPathComponent
        for child in children.sorted() where child != own {
            let lower = child.lowercased()
            guard lower.hasPrefix("uninstall") || lower.contains("uninstaller") else { continue }
            let path = (folder as NSString).appendingPathComponent(child)
            if lower.hasSuffix(".app") || isDirectory(path) && FileManager.default.fileExists(atPath: path + "/Contents/Info.plist") || lower.hasSuffix(".app") == false && FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Only what macOS itself protects is refused: the /System volume and apps flagged by System
    /// Integrity Protection (Safari and the other built-in apps). Apple apps from the App Store
    /// (GarageBand, iMovie, Pages, Keynote, Numbers…) can be removed like any other app.
    public static func protectionReason(path: String, bundleID: String?) -> String? {
        if path.hasPrefix("/System/") { return "Part of macOS." }
        if isSIPProtected(path) { return "Protected by macOS (System Integrity Protection)." }
        if bundleID?.lowercased() == "com.czcommander.macos" { return "CZ.commander cannot uninstall itself." }
        return nil
    }

    /// The "restricted" file flag set by System Integrity Protection.
    public static func isSIPProtected(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_flags & UInt32(SF_RESTRICTED)) != 0
    }

    /// The error macOS gives when an app lacks the "App Management" permission to change or
    /// remove other apps (Ventura and later), or plain file permissions are missing.
    public static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && (ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError) {
            return true
        }
        if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EPERM) || ns.code == Int(EACCES)) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionError(underlying) }
        let text = ns.localizedDescription.lowercased()
        return text.contains("not permitted") || text.contains("permission")
    }

    // MARK: Identity

    /// Bundle ids of the app and of every bundle inside it (helpers, login items, XPC
    /// services, app extensions, system extensions). They own containers and preferences too.
    public static func relatedBundleIDs(appPath: String, mainID: String?) -> [String] {
        var ids: [String] = []
        if let mainID { ids.append(mainID) }
        let contents = (appPath as NSString).appendingPathComponent("Contents")
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: contents) else { return ids }
        let bundleExts: Set<String> = ["app", "xpc", "appex", "systemextension", "bundle", "framework", "plugin", "kext"]
        while let rel = e.nextObject() as? String {
            let ext = (rel as NSString).pathExtension.lowercased()
            guard bundleExts.contains(ext) else { continue }
            // Frameworks and plug-ins do not own data; only look inside them for nested apps.
            guard ext == "app" || ext == "xpc" || ext == "appex" || ext == "systemextension" else { continue }
            let plist = (contents as NSString).appendingPathComponent(rel + "/Contents/Info.plist")
            let alt = (contents as NSString).appendingPathComponent(rel + "/Info.plist")
            let info = (NSDictionary(contentsOfFile: plist) ?? NSDictionary(contentsOfFile: alt)) as? [String: Any]
            if let id = info?["CFBundleIdentifier"] as? String, !id.isEmpty, !ids.contains(id),
               !id.contains("@"), !id.contains("$("),
               !id.lowercased().hasPrefix("com.apple.") {
                ids.append(id)
            }
        }
        return ids
    }

    /// Team identifier from the code signature ("UBF8T346G9"), nil for unsigned / ad-hoc apps.
    public static func teamIdentifier(appPath: String) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: appPath) as CFURL, [], &code) == errSecSuccess,
              let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
        return (team?.isEmpty == false) ? team : nil
    }

    // MARK: Leftovers

    public struct SearchContext: Sendable {
        public let home: String
        /// "" normally; tests point it at a temporary folder that mirrors /Library.
        public let systemRoot: String
        public let userCacheDir: String?
        public let userTempDir: String?

        public init(home: String, systemRoot: String = "", userCacheDir: String? = nil, userTempDir: String? = nil) {
            self.home = home
            self.systemRoot = systemRoot
            self.userCacheDir = userCacheDir
            self.userTempDir = userTempDir
        }

        public static var current: SearchContext {
            SearchContext(
                home: NSHomeDirectory(),
                userCacheDir: darwinDir(_CS_DARWIN_USER_CACHE_DIR),
                userTempDir: darwinDir(_CS_DARWIN_USER_TEMP_DIR))
        }

        static func darwinDir(_ name: Int32) -> String? {
            let len = confstr(name, nil, 0)
            guard len > 0 else { return nil }
            var buf = [CChar](repeating: 0, count: len)
            confstr(name, &buf, len)
            let s = String(cString: buf)
            return s.isEmpty ? nil : (s as NSString).standardizingPath
        }
    }

    struct Matcher {
        let ids: [String]          // lowercased bundle ids, the app's own first
        let foreignIDs: Set<String> // bundled components that are not under the app's own id
        let names: [String]        // lowercased app / executable names
        let team: String?          // lowercased team id

        /// How `name` relates to the app's ids: exact (also "<id>.plist", "<id>.savedState",
        /// "<id>.binarycookies", ByHost "<id>.<host-uuid>.plist") or only by prefix; and
        /// whether the id is a shared component.
        func idClass(_ name: String) -> (exact: Bool, foreign: Bool)? {
            var n = name.lowercased()
            for ext in [".plist", ".savedstate", ".binarycookies"] where n.hasSuffix(ext) {
                n.removeLast(ext.count)
                break
            }
            var prefixHit: (exact: Bool, foreign: Bool)? = nil
            for id in ids {
                let foreign = foreignIDs.contains(id)
                if n == id { return (true, foreign) }
                if n.hasPrefix(id + ".") {
                    let rest = n.dropFirst(id.count + 1)
                    if rest.count >= 8 && rest.allSatisfy({ $0.isHexDigit || $0 == "-" }) { return (true, foreign) }
                    if prefixHit == nil { prefixHit = (false, foreign) }
                }
            }
            return prefixHit
        }

        func idMatch(_ name: String) -> Bool { idClass(name) != nil }

        /// Some id appears inside `name`; `own` true when one of the app's own ids does.
        func containedID(_ name: String) -> (own: Bool, any: Bool) {
            let n = name.lowercased()
            let hits = ids.filter { n.contains($0) }
            return (hits.contains { !foreignIDs.contains($0) }, !hits.isEmpty)
        }

        func containsID(_ name: String) -> Bool { containedID(name).any }

        func nameMatch(_ name: String) -> Bool {
            let n = name.lowercased()
            return names.contains { n == $0 }
        }
    }

    static func makeMatcher(app: InstalledApp, relatedIDs: [String], teamID: String?) -> Matcher {
        var names: [String] = []
        for n in [app.name, ((app.path as NSString).lastPathComponent as NSString).deletingPathExtension, app.executableName ?? ""] {
            let l = n.lowercased().trimmingCharacters(in: .whitespaces)
            // Very short or generic names would match unrelated folders.
            guard l.count >= 3, !genericNames.contains(l), !names.contains(l) else { continue }
            names.append(l)
        }
        // Bundle ids shorter than "a.bc" are not trustworthy enough to match on.
        let ids = relatedIDs.map { $0.lowercased() }.filter { $0.count >= 4 && $0.contains(".") }
        let main = app.bundleID?.lowercased()
        let foreign = Set(ids.filter { id in main.map { id != $0 && !id.hasPrefix($0 + ".") } ?? false })
        return Matcher(ids: ids, foreignIDs: foreign, names: names, team: teamID?.lowercased())
    }

    static let genericNames: Set<String> = [
        "app", "apps", "application", "applications", "cache", "caches", "data", "default", "helper",
        "launcher", "logs", "preferences", "settings", "support", "temp", "tmp", "update", "updater",
        "installer", "uninstaller", "plugins", "plug-ins", "user", "users", "library", "documents",
        "google", "microsoft", "adobe", "apple", "mozilla", "jetbrains", "electron", "chrome",
    ]

    /// Finds the app's leftovers. `measure` false skips sizes (tests, quick listing).
    public static func plan(for app: InstalledApp, context: SearchContext = .current, measure: Bool = true) -> AppUninstallPlan {
        let related = relatedBundleIDs(appPath: app.path, mainID: app.bundleID)
        let team = teamIdentifier(appPath: app.path)
        let leftovers = findLeftovers(app: app, relatedIDs: related, teamID: team, context: context, measure: measure)
        return AppUninstallPlan(
            app: app,
            bundleSize: measure ? allocatedSize(app.path) : 0,
            relatedBundleIDs: related,
            teamID: team,
            leftovers: leftovers)
    }

    public static func findLeftovers(app: InstalledApp, relatedIDs: [String], teamID: String?, context: SearchContext, measure: Bool) -> [AppLeftover] {
        let m = makeMatcher(app: app, relatedIDs: relatedIDs, teamID: teamID)
        let home = context.home
        let sys = context.systemRoot
        var found: [String: AppLeftover] = [:]
        var order: [String] = []

        func add(_ path: String, _ category: String, _ match: AppLeftoverMatch, preselected: Bool = true, admin: Bool = false, label: String? = nil) {
            guard found[path] == nil, isSafeLeftover(path, context: context), path != app.path,
                  !isInside(path, of: app.path) else { return }
            found[path] = AppLeftover(path: path, category: category, match: match, sizeBytes: 0,
                                      preselected: preselected, needsAdmin: admin, launchLabel: label)
            order.append(path)
        }

        /// Children of `dir` (no recursion, symlinks skipped). Type info comes in one bulk
        /// call instead of a stat per entry (Containers holds hundreds of folders).
        func entries(_ dir: String) -> [(name: String, path: String, isDir: Bool)] {
            let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey]
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: dir, isDirectory: true), includingPropertiesForKeys: keys, options: []) else { return [] }
            var out: [(String, String, Bool)] = []
            for url in urls {
                let name = url.lastPathComponent
                guard name != ".DS_Store" else { continue }
                let v = try? url.resourceValues(forKeys: Set(keys))
                if v?.isSymbolicLink == true { continue }
                out.append((name, (dir as NSString).appendingPathComponent(name), v?.isDirectory ?? false))
            }
            return out
        }
        func children(_ dir: String) -> [(name: String, path: String)] {
            entries(dir).map { ($0.name, $0.path) }
        }

        func addByID(_ path: String, _ name: String, _ category: String, admin: Bool = false) {
            guard let c = m.idClass(name) else { return }
            let mine = c.exact && !c.foreign
            add(path, category, mine ? .bundleID : .related, preselected: mine, admin: admin)
        }

        /// Folder of support data: bundle id, exact app name, or "<Vendor>/<Product>" where
        /// "Vendor Product" is the app name (Google/Chrome for "Google Chrome").
        func scanNamed(_ dir: String, _ category: String, admin: Bool = false) {
            for (name, path, isDir) in entries(dir) {
                if m.idMatch(name) {
                    addByID(path, name, category, admin: admin)
                } else if m.nameMatch(name) {
                    add(path, category, .name, admin: admin)
                } else if isDir, !m.names.isEmpty {
                    let vendor = name.lowercased()
                    for (sub, subPath) in children(path) {
                        let combined = vendor + " " + sub.lowercased()
                        if m.idMatch(sub) {
                            addByID(subPath, sub, category, admin: admin)
                        } else if m.names.contains(combined) {
                            add(subPath, category, .name, admin: admin)
                        }
                    }
                }
            }
        }

        func scanIDs(_ dir: String, _ category: String, admin: Bool = false) {
            for (name, path) in children(dir) {
                addByID(path, name, category, admin: admin)
            }
        }

        func scanLaunch(_ dir: String, _ category: String, admin: Bool) {
            for (name, path) in children(dir) where name.lowercased().hasSuffix(".plist") {
                let label = (NSDictionary(contentsOfFile: path)?["Label"] as? String)
                let program = launchProgram(path)
                let byFile = m.containedID(name)
                let byLabel = label.map { m.containedID($0) } ?? (own: false, any: false)
                let byProgram = program.map { $0 == app.path || $0.hasPrefix(app.path + "/") } ?? false
                if byProgram || byFile.own || byLabel.own {
                    add(path, category, .bundleID, admin: admin, label: label)
                } else if byFile.any || byLabel.any {
                    add(path, category, .related, preselected: false, admin: admin, label: label)
                }
            }
        }

        let lib = home + "/Library"
        scanNamed(lib + "/Application Support", "Application Support")
        scanNamed(lib + "/Caches", "Caches")
        scanIDs(lib + "/Preferences", "Preferences")
        scanIDs(lib + "/Preferences/ByHost", "Preferences")
        scanIDs(lib + "/Containers", "Containers")
        scanIDs(lib + "/Application Scripts", "Application Scripts")
        scanIDs(lib + "/Saved Application State", "Saved State")
        scanIDs(lib + "/HTTPStorages", "Web Data")
        scanIDs(lib + "/WebKit", "Web Data")
        scanIDs(lib + "/Cookies", "Web Data")
        scanIDs(lib + "/Autosave Information", "Autosave")
        scanNamed(lib + "/Logs", "Logs")
        scanLaunch(lib + "/LaunchAgents", "Launch Agents", admin: false)

        // Group containers: "<TEAM>.<group>" or "group.<id>". A container that names one of the
        // app's ids is its own; one that only shares the team id may belong to sibling apps.
        for (name, path) in children(lib + "/Group Containers") {
            let n = name.lowercased()
            let contained = m.containedID(n)
            if contained.any {
                add(path, "Group Containers", contained.own ? .bundleID : .related, preselected: contained.own)
            } else if let team = m.team, n.hasPrefix(team + "."),
                      m.names.contains(where: { n.contains($0.replacingOccurrences(of: " ", with: "")) }) {
                add(path, "Group Containers", .team, preselected: false)
            }
        }
        // Application Scripts for team-prefixed groups ("<TEAM>.com.vendor.app").
        if let team = m.team {
            for (name, path) in children(lib + "/Application Scripts") where name.lowercased().hasPrefix(team + ".") {
                let contained = m.containedID(name)
                if contained.any {
                    add(path, "Application Scripts", contained.own ? .bundleID : .related, preselected: contained.own)
                }
            }
        }

        // Crash reports named after the executable ("Foo-2026-11-23-101010.ips", "Foo_2026…crash").
        let crashNames = m.names
        for dir in [lib + "/Logs/DiagnosticReports", lib + "/Logs/DiagnosticReports/Retired"] {
            for (name, path) in children(dir) {
                let n = name.lowercased()
                let ext = (n as NSString).pathExtension
                guard ["ips", "crash", "diag", "spin", "hang"].contains(ext) else { continue }
                if crashNames.contains(where: { n.hasPrefix($0 + "-") || n.hasPrefix($0 + "_") || n.hasPrefix($0 + ".") }) {
                    add(path, "Crash Reports", .name)
                }
            }
        }

        // Per-user cache / temp folders under /private/var/folders.
        for dir in [context.userCacheDir, context.userTempDir].compactMap({ $0 }) {
            scanIDs(dir, "Temporary Files")
        }

        // System-wide locations (an administrator password is asked when these are moved).
        let slib = sys + "/Library"
        scanNamed(slib + "/Application Support", "Application Support (all users)", admin: true)
        scanIDs(slib + "/Caches", "Caches (all users)", admin: true)
        scanIDs(slib + "/Preferences", "Preferences (all users)", admin: true)
        scanNamed(slib + "/Logs", "Logs (all users)", admin: true)
        scanLaunch(slib + "/LaunchAgents", "Launch Agents (all users)", admin: true)
        scanLaunch(slib + "/LaunchDaemons", "Launch Daemons", admin: true)
        scanIDs(slib + "/PrivilegedHelperTools", "Privileged Helpers", admin: true)

        var result = order.compactMap { found[$0] }
        // Drop entries that sit inside another found entry (counted twice otherwise).
        let paths = Set(result.map(\.path))
        result.removeAll { item in paths.contains { $0 != item.path && isInside(item.path, of: $0) } }
        if measure {
            for i in result.indices { result[i].sizeBytes = allocatedSize(result[i].path) }
        }
        return result
    }

    static func launchProgram(_ plistPath: String) -> String? {
        guard let d = NSDictionary(contentsOfFile: plistPath) as? [String: Any] else { return nil }
        if let p = d["Program"] as? String { return p }
        if let a = d["ProgramArguments"] as? [String], let first = a.first { return first }
        return nil
    }

    // MARK: Safety

    /// Leftovers must sit directly in an allowlisted Library sub-folder (or one level deeper
    /// for "<Vendor>/<Product>"), never be a root Library folder itself, and never be a link.
    public static func isSafeLeftover(_ path: String, context: SearchContext = .current) -> Bool {
        let p = (path as NSString).standardizingPath
        guard p == path, p.hasPrefix("/"), !isSymlink(p) else { return false }
        let roots = allowedRoots(home: context.home, systemRoot: context.systemRoot)
        for root in roots where p.hasPrefix(root + "/") {
            let rest = String(p.dropFirst(root.count + 1))
            let depth = rest.split(separator: "/").count
            guard depth >= 1 && depth <= 2, !rest.contains("..") else { return false }
            // Two levels only for vendor folders in Application Support / Caches / Logs.
            if depth == 2 && !(root.hasSuffix("/Application Support") || root.hasSuffix("/Caches") || root.hasSuffix("/Logs")
                               || root.hasSuffix("/DiagnosticReports")) {
                return false
            }
            return true
        }
        let tmp = [context.userCacheDir, context.userTempDir].compactMap { $0 }
        for root in tmp where p.hasPrefix(root + "/") {
            return String(p.dropFirst(root.count + 1)).split(separator: "/").count == 1
        }
        return false
    }

    static func allowedRoots(home: String, systemRoot: String) -> [String] {
        let user = ["Application Support", "Caches", "Preferences", "Preferences/ByHost", "Containers", "Group Containers",
                    "Application Scripts", "Saved Application State", "HTTPStorages", "WebKit", "Cookies",
                    "Autosave Information", "Logs", "Logs/DiagnosticReports", "Logs/DiagnosticReports/Retired", "LaunchAgents"]
            .map { home + "/Library/" + $0 }
        let system = ["Application Support", "Caches", "Preferences", "Logs", "LaunchAgents", "LaunchDaemons", "PrivilegedHelperTools"]
            .map { systemRoot + "/Library/" + $0 }
        // Longest first so "Logs/DiagnosticReports" wins over "Logs".
        return (user + system).sorted { $0.count > $1.count }
    }

    // MARK: File helpers

    public static func isSymlinkPath(_ path: String) -> Bool { isSymlink(path) }

    static func isSymlink(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    static func isInside(_ path: String, of ancestor: String) -> Bool {
        path.hasPrefix(ancestor.hasSuffix("/") ? ancestor : ancestor + "/")
    }

    /// Allocated size on disk; links are not followed, hard links counted once.
    public static func allocatedSize(_ path: String) -> Int64 {
        var total: Int64 = 0
        var seen = Set<UInt64>()
        func addFile(_ p: String) {
            var st = stat()
            guard lstat(p, &st) == 0 else { return }
            if st.st_nlink > 1 {
                guard seen.insert(UInt64(st.st_ino)).inserted else { return }
            }
            total += Int64(st.st_blocks) * 512
        }
        var st = stat()
        guard lstat(path, &st) == 0 else { return 0 }
        if (st.st_mode & S_IFMT) != S_IFDIR {
            addFile(path)
            return total
        }
        total += Int64(st.st_blocks) * 512
        guard let e = FileManager.default.enumerator(atPath: path) else { return total }
        while let rel = e.nextObject() as? String {
            addFile((path as NSString).appendingPathComponent(rel))
        }
        return total
    }
}
