import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Startup items: lists what macOS starts at login or boot and lets the user turn single items
// off and on again. Reasoning, sources and the list of what is deliberately not touched are in
// docs/STARTUP.md.
//
// Three sources:
//   - Login Items (System Settings > General > Login Items): read and changed through System
//     Events (AppleScript). Turning one off removes it from the list, so its path is remembered
//     in CZ.commander's own file and it can be added back.
//   - Launch Agents in ~/Library/LaunchAgents and /Library/LaunchAgents: turned off with
//     `launchctl disable gui/<uid>/<label>`, which is launchd's own per-user override. The plist
//     is never edited or deleted, so turning the item on again restores exactly what was there.
//   - Launch Daemons in /Library/LaunchDaemons: listed only; they run as root.
//
// Items that macOS 13+ registers through its newer background-item mechanism ("Allow in the
// Background" in System Settings) cannot be switched by another app; the window links there.

// MARK: - Model

public enum StartupItemKind: String, Sendable, CaseIterable {
    case loginItem
    case userAgent
    case systemAgent
    case systemDaemon

    public var title: String {
        switch self {
        case .loginItem: return "Login Items"
        case .userAgent: return "Launch Agents of this user"
        case .systemAgent: return "Launch Agents for all users"
        case .systemDaemon: return "Launch Daemons (system services, start at boot)"
        }
    }

    public var detail: String {
        switch self {
        case .loginItem: return "Apps that open when you log in (System Settings → General → Login Items)."
        case .userAgent: return "Background helpers installed in ~/Library/LaunchAgents."
        case .systemAgent: return "Background helpers installed for every user in /Library/LaunchAgents. Turning one off affects only your account."
        case .systemDaemon: return "Run as administrator before anyone logs in. Shown for information: changing them needs administrator rights."
        }
    }

    public var symbolName: String {
        switch self {
        case .loginItem: return "person.crop.circle.badge.checkmark"
        case .userAgent, .systemAgent: return "gearshape.2"
        case .systemDaemon: return "server.rack"
        }
    }
}

public enum StartupTrigger: String, Sendable {
    /// Starts when you log in (RunAtLoad, or KeepAlive).
    case atLogin
    /// Starts on a timer.
    case scheduled
    /// Starts when a file changes or a condition becomes true.
    case onEvent
    /// Only starts when another program asks for it (a helper of an app).
    case onDemand

    public var text: String {
        switch self {
        case .atLogin: return "Starts at login"
        case .scheduled: return "Runs on a schedule"
        case .onEvent: return "Starts on a file change or condition"
        case .onDemand: return "Starts only when an app asks for it"
        }
    }
}

public enum StartupRunState: String, Sendable {
    case running, loaded, notLoaded, unknown
}

public struct StartupItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: StartupItemKind
    public var name: String
    /// launchd label (agents and daemons).
    public var label: String?
    public var plistPath: String?
    /// The program that starts (login items: the app).
    public var programPath: String?
    /// The enclosing `.app`, if any (used for the icon).
    public var appPath: String?
    /// `true` = starts as configured, `false` = turned off.
    public var enabled: Bool
    public var runState: StartupRunState
    public var trigger: StartupTrigger
    public var keepsRunning: Bool
    /// The program file does not exist any more (usually left behind by an uninstalled app).
    public var programMissing: Bool
    public var isApple: Bool
    /// Security, VPN or device-management software: turning it off has side effects.
    public var cautionReason: String?
    /// `nil` = the switch works, otherwise why it does not.
    public var toggleBlockedReason: String?
    public var loginItemHidden: Bool
    /// A login item that CZ.commander removed from the list and remembers.
    public var removedByUs: Bool

    public var canToggle: Bool { toggleBlockedReason == nil }
}

public struct StartupScanResult: Sendable {
    public let items: [StartupItem]
    /// Why the Login Items list could not be read (nil = fine).
    public let loginItemsError: String?
    /// macOS has to allow CZ.commander to control System Events first.
    public let loginItemsNeedPermission: Bool
    public let unreadablePlists: [String]
}

public struct StartupActionResult: Sendable {
    public let success: Bool
    public let message: String
}

// MARK: - Running commands

public struct StartupCommandResult: Sendable {
    public let status: Int32
    public let output: String
    public let error: String

    public init(status: Int32, output: String = "", error: String = "") {
        self.status = status
        self.output = output
        self.error = error
    }
}

/// Runs `launchctl` and `osascript`. A protocol so tests can answer without a Mac.
public protocol StartupCommandRunner: Sendable {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> StartupCommandResult
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

public struct ProcessCommandRunner: StartupCommandRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> StartupCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return StartupCommandResult(status: -1, error: error.localizedDescription)
        }
        let flag = TimeoutFlag()
        let killer = DispatchWorkItem {
            if process.isRunning { flag.set(); process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        let out = String(decoding: outData, as: UTF8.self)
        var err = String(decoding: errData, as: UTF8.self)
        if flag.isSet { err = "Timed out after \(Int(timeout)) s" }
        return StartupCommandResult(status: flag.isSet ? -1 : process.terminationStatus, output: out, error: err)
    }
}

public struct StartupEnvironment: Sendable {
    public var home: String
    /// Prefix for system folders (`""` on a real Mac, a sandbox folder in tests).
    public var systemRoot: String
    public var userID: UInt32
    public var runner: any StartupCommandRunner
    /// Where CZ.commander remembers login items it removed.
    public var storePath: String

    public init(home: String, systemRoot: String = "", userID: UInt32 = getuid(),
                runner: any StartupCommandRunner = ProcessCommandRunner(), storePath: String? = nil) {
        self.home = home
        self.systemRoot = systemRoot
        self.userID = userID
        self.runner = runner
        self.storePath = storePath ?? home + "/Library/Application Support/CZ.commander/startup.json"
    }

    public static func current() -> StartupEnvironment {
        StartupEnvironment(home: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    var userAgentsDirectory: String { home + "/Library/LaunchAgents" }
    var systemAgentsDirectory: String { systemRoot + "/Library/LaunchAgents" }
    var systemDaemonsDirectory: String { systemRoot + "/Library/LaunchDaemons" }
}

// MARK: - Remembered login items

struct RemovedLoginItem: Codable, Hashable, Sendable {
    var name: String
    var path: String
    var hidden: Bool
    var removedAt: Date
}

enum StartupStore {
    static func load(_ path: String) -> [RemovedLoginItem] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([RemovedLoginItem].self, from: data)) ?? []
    }

    static func save(_ items: [RemovedLoginItem], to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(items).write(to: url, options: .atomic)
    }
}

// MARK: - Engine

public enum StartupEngine {

    // MARK: Parsing launchctl / osascript output

    /// `launchctl print-disabled <domain>`: `"label" => disabled` (macOS 11+) or `=> true` (older).
    /// Returns label -> isDisabled.
    static func parseDisabledList(_ text: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("\"") else { continue }
            let afterQuote = line.dropFirst()
            guard let closing = afterQuote.firstIndex(of: "\"") else { continue }
            let label = String(afterQuote[..<closing])
            let rest = afterQuote[afterQuote.index(after: closing)...]
            guard let arrow = rest.range(of: "=>") else { continue }
            let value = rest[arrow.upperBound...]
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t;,"))
                .lowercased()
            switch value {
            case "disabled", "true": result[label] = true
            case "enabled", "false": result[label] = false
            default: break
            }
        }
        return result
    }

    /// `launchctl list`: `PID  Status  Label`. Returns label -> pid (-1 = loaded but not running).
    static func parseLaunchctlList(_ text: String) -> [String: Int] {
        var result: [String: Int] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let parts = raw.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: { $0 == "\t" || $0 == " " })
            guard parts.count == 3, parts[0] != "PID" else { continue }
            result[String(parts[2])] = Int(parts[0]) ?? -1
        }
        return result
    }

    struct LiveLoginItem: Hashable {
        var name: String
        var path: String
        var hidden: Bool
    }

    /// Output of the listing script: `name <TAB> path <TAB> hidden` per line.
    static func parseLoginItems(_ text: String) -> [LiveLoginItem] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, !parts[0].isEmpty else { return nil }
            let path = parts[1] == "missing value" ? "" : parts[1]
            return LiveLoginItem(name: parts[0], path: path, hidden: parts[2].lowercased() == "true")
        }
    }

    // MARK: Classifying a launchd plist

    /// launchd labels are plain identifiers; anything else is not passed to `launchctl`.
    static func isValidLabel(_ label: String) -> Bool {
        guard !label.isEmpty, label.count <= 200, !label.hasPrefix("-") else { return false }
        return label.unicodeScalars.allSatisfy { s in
            (48...57).contains(s.value) || (65...90).contains(s.value) || (97...122).contains(s.value)
                || s == "." || s == "_" || s == "-" || s == "+"
        }
    }

    private static let interpreters: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "tcsh", "env", "python", "python3", "perl", "ruby", "osascript", "node", "open"
    ]

    /// The program a plist starts. For a wrapper like `/bin/sh /path/script.sh`, the script.
    static func programPath(from plist: [String: Any]) -> String? {
        if let program = plist["Program"] as? String, !program.isEmpty { return program }
        guard let args = plist["ProgramArguments"] as? [String], let first = args.first else { return nil }
        if interpreters.contains((first as NSString).lastPathComponent) {
            return args.dropFirst().first { $0.hasPrefix("/") }
        }
        return first
    }

    /// `/Applications/X.app/Contents/MacOS/x` -> `/Applications/X.app`.
    static func enclosingApp(of path: String) -> String? {
        var built = ""
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            built += "/" + part
            if part.lowercased().hasSuffix(".app") { return built }
        }
        return nil
    }

    static func classify(_ plist: [String: Any]) -> (trigger: StartupTrigger, keepsRunning: Bool) {
        let runAtLoad = (plist["RunAtLoad"] as? Bool) ?? false
        let keepAliveBool = plist["KeepAlive"] as? Bool
        let keepAliveConditions = (plist["KeepAlive"] as? [String: Any]).map { !$0.isEmpty } ?? false
        let keeps = keepAliveBool == true || keepAliveConditions
        if runAtLoad || keepAliveBool == true { return (.atLogin, keeps) }
        if plist["StartInterval"] != nil || plist["StartCalendarInterval"] != nil { return (.scheduled, keeps) }
        if plist["WatchPaths"] != nil || plist["QueueDirectories"] != nil || keepAliveConditions { return (.onEvent, keeps) }
        return (.onDemand, keeps)
    }

    /// Names that usually mean security, device-management or VPN software.
    private static let cautionWords: [String] = [
        "jamf", "crowdstrike", "falcon", "sentinelone", "kandji", "mosyle", "intune", "companyportal",
        "wdav", "defender", "carbonblack", "sophos", "cylance", "malwarebytes", "littlesnitch", "objective-see",
        "vpn", "wireguard", "tailscale", "anyconnect", "globalprotect", "zscaler", "forcepoint", "nordlayer"
    ]

    static func cautionReason(_ texts: [String]) -> String? {
        let haystack = texts.joined(separator: " ").lowercased()
        guard cautionWords.contains(where: { haystack.contains($0) }) else { return nil }
        return "Looks like security, VPN or device-management software: turning it off can leave the Mac unprotected, drop the VPN, or be reported to your administrator."
    }

    // MARK: Scanning

    public static func scan(environment env: StartupEnvironment) -> StartupScanResult {
        let uid = env.userID
        let userDisabled = parseDisabledList(env.runner.run("/bin/launchctl", ["print-disabled", "gui/\(uid)"], timeout: 15).output)
        let systemDisabled = parseDisabledList(env.runner.run("/bin/launchctl", ["print-disabled", "system"], timeout: 15).output)
        let jobs = parseLaunchctlList(env.runner.run("/bin/launchctl", ["list"], timeout: 15).output)

        var unreadable: [String] = []
        var items: [StartupItem] = []

        let loginResult = scanLoginItems(env)
        items += loginResult.items
        items += scanLaunchDirectory(env.userAgentsDirectory, kind: .userAgent, disabled: userDisabled, jobs: jobs, unreadable: &unreadable)
        items += scanLaunchDirectory(env.systemAgentsDirectory, kind: .systemAgent, disabled: userDisabled, jobs: jobs, unreadable: &unreadable)
        items += scanLaunchDirectory(env.systemDaemonsDirectory, kind: .systemDaemon, disabled: systemDisabled, jobs: [:], unreadable: &unreadable)

        let kindOrder = StartupItemKind.allCases
        items.sort { a, b in
            if a.kind != b.kind { return kindOrder.firstIndex(of: a.kind)! < kindOrder.firstIndex(of: b.kind)! }
            let ra = a.trigger == .atLogin ? 0 : 1, rb = b.trigger == .atLogin ? 0 : 1
            if ra != rb { return ra < rb }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return StartupScanResult(items: items, loginItemsError: loginResult.error,
                                 loginItemsNeedPermission: loginResult.needsPermission, unreadablePlists: unreadable)
    }

    private static func scanLaunchDirectory(
        _ dir: String, kind: StartupItemKind, disabled: [String: Bool], jobs: [String: Int], unreadable: inout [String]
    ) -> [StartupItem] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var items: [StartupItem] = []
        for file in names.sorted() where file.hasSuffix(".plist") && !file.hasPrefix(".") {
            let path = dir + "/" + file
            guard let data = fm.contents(atPath: path),
                  let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else {
                unreadable.append(path)
                continue
            }
            let label = (plist["Label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? String(file.dropLast(".plist".count))
            let program = programPath(from: plist)
            let app = program.flatMap(enclosingApp(of:))
            let name = app.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? label
            let (trigger, keeps) = classify(plist)
            let plistDisabled = (plist["Disabled"] as? Bool) ?? false
            // launchd's override database wins over the plist's own Disabled key.
            let isDisabled = disabled[label] ?? plistDisabled
            let isApple = label.hasPrefix("com.apple.") || (program?.hasPrefix("/System/") ?? false)

            var blocked: String? = nil
            if kind == .systemDaemon {
                blocked = "Needs administrator rights. Use System Settings → General → Login Items & Extensions, or sudo launchctl disable system/\(label)."
            } else if isApple {
                blocked = "Part of macOS: turning it off can break the system."
            } else if !isValidLabel(label) {
                blocked = "Unusual label: change this one with launchctl yourself."
            }

            var runState = StartupRunState.unknown
            if kind != .systemDaemon {
                if let pid = jobs[label] { runState = pid >= 0 ? .running : .loaded } else { runState = .notLoaded }
            }
            let missing: Bool = {
                guard let program, program.hasPrefix("/") else { return false }
                return !fm.fileExists(atPath: program)
            }()

            items.append(StartupItem(
                id: "\(kind.rawValue):\(path)", kind: kind, name: name, label: label, plistPath: path,
                programPath: program, appPath: app, enabled: !isDisabled, runState: runState, trigger: trigger,
                keepsRunning: keeps, programMissing: missing, isApple: isApple,
                cautionReason: cautionReason([label, program ?? "", name]),
                toggleBlockedReason: blocked, loginItemHidden: false, removedByUs: false
            ))
        }
        return items
    }

    // MARK: Login items (System Events)

    static let listLoginItemsScript: [String] = [
        "tell application \"System Events\"",
        "set out to \"\"",
        "repeat with li in every login item",
        "set out to out & (name of li) & (ASCII character 9) & (path of li) & (ASCII character 9) & ((hidden of li) as string) & linefeed",
        "end repeat",
        "return out",
        "end tell"
    ]

    static let removeLoginItemScript: [String] = [
        "on run argv",
        "set targetName to item 1 of argv",
        "tell application \"System Events\" to delete (every login item whose name is targetName)",
        "end run"
    ]

    static let addLoginItemScript: [String] = [
        "on run argv",
        "set targetPath to item 1 of argv",
        "set makeHidden to (item 2 of argv) is \"true\"",
        "tell application \"System Events\" to make login item at end with properties {path:targetPath, hidden:makeHidden}",
        "end run"
    ]

    /// `osascript -e line -e line … arguments`. Arguments reach the script as `argv`, so a name or
    /// path can never be read as AppleScript code.
    static func osascriptArguments(_ script: [String], _ arguments: [String] = []) -> [String] {
        script.flatMap { ["-e", $0] } + arguments
    }

    static func friendlyAppleScriptError(_ stderr: String) -> (text: String, needsPermission: Bool) {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("-1743") || trimmed.localizedCaseInsensitiveContains("not authorized") {
            return ("macOS did not allow CZ.commander to control System Events. Allow it in System Settings → Privacy & Security → Automation, then reload.", true)
        }
        return (trimmed.isEmpty ? "System Events did not answer" : trimmed, false)
    }

    private static func scanLoginItems(_ env: StartupEnvironment) -> (items: [StartupItem], error: String?, needsPermission: Bool) {
        let fm = FileManager.default
        let result = env.runner.run("/usr/bin/osascript", osascriptArguments(listLoginItemsScript), timeout: 120)
        var live: [LiveLoginItem] = []
        var error: String? = nil
        var needsPermission = false
        if result.status == 0 {
            live = parseLoginItems(result.output)
        } else {
            let friendly = friendlyAppleScriptError(result.error)
            error = friendly.text
            needsPermission = friendly.needsPermission
        }

        // Forget removed items that were added again by hand.
        var remembered = StartupStore.load(env.storePath)
        let kept = remembered.filter { rec in !live.contains { $0.path == rec.path } }
        if kept.count != remembered.count, error == nil {
            try? StartupStore.save(kept, to: env.storePath)
            remembered = kept
        }

        func make(name: String, path: String, hidden: Bool, enabled: Bool, removedByUs: Bool) -> StartupItem {
            let app = enclosingApp(of: path)
            return StartupItem(
                id: "\(StartupItemKind.loginItem.rawValue):\(name)|\(path)", kind: .loginItem, name: name, label: nil,
                plistPath: nil, programPath: path.isEmpty ? nil : path, appPath: app, enabled: enabled,
                runState: .unknown, trigger: .atLogin, keepsRunning: false,
                programMissing: path.isEmpty || !fm.fileExists(atPath: path), isApple: false,
                cautionReason: cautionReason([name, path]), toggleBlockedReason: nil,
                loginItemHidden: hidden, removedByUs: removedByUs
            )
        }
        var items = live.map { make(name: $0.name, path: $0.path, hidden: $0.hidden, enabled: true, removedByUs: false) }
        // Without a readable list we cannot tell which remembered items were added back, so show none.
        if error == nil {
            items += remembered.map { make(name: $0.name, path: $0.path, hidden: $0.hidden, enabled: false, removedByUs: true) }
        }
        return (items, error, needsPermission)
    }

    // MARK: Turning items on and off

    public static func setEnabled(_ item: StartupItem, to enabled: Bool, environment env: StartupEnvironment) -> StartupActionResult {
        if let reason = item.toggleBlockedReason { return StartupActionResult(success: false, message: reason) }
        switch item.kind {
        case .systemDaemon:
            return StartupActionResult(success: false, message: "Launch daemons need administrator rights.")
        case .userAgent, .systemAgent:
            return setAgentEnabled(item, to: enabled, env)
        case .loginItem:
            return enabled ? restoreLoginItem(item, env) : removeLoginItem(item, env)
        }
    }

    private static func failureText(_ result: StartupCommandResult) -> String {
        let text = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "launchctl failed (status \(result.status))" : text
    }

    private static func setAgentEnabled(_ item: StartupItem, to enabled: Bool, _ env: StartupEnvironment) -> StartupActionResult {
        guard let label = item.label, isValidLabel(label), let plist = item.plistPath else {
            return StartupActionResult(success: false, message: "This item has no usable launchd label.")
        }
        // Only plists that live in a launch agent folder are ever handled.
        let folder = (plist as NSString).deletingLastPathComponent
        guard folder == env.userAgentsDirectory || folder == env.systemAgentsDirectory else {
            return StartupActionResult(success: false, message: "Not in a launch agent folder.")
        }
        let domain = "gui/\(env.userID)"
        let target = "\(domain)/\(label)"
        var stoppedNow = false
        if enabled {
            let r = env.runner.run("/bin/launchctl", ["enable", target], timeout: 15)
            if r.status != 0 { return StartupActionResult(success: false, message: failureText(r)) }
        } else {
            let r = env.runner.run("/bin/launchctl", ["disable", target], timeout: 15)
            if r.status != 0 { return StartupActionResult(success: false, message: failureText(r)) }
            // Stop it now; failing only means it was not running.
            stoppedNow = env.runner.run("/bin/launchctl", ["bootout", target], timeout: 15).status == 0
        }
        // Trust but verify: ask launchd what it recorded. Apple says launchctl's printed output is
        // not a stable interface, so if it no longer looks like `"label" => state` at all, the
        // check is skipped (and said so) instead of reporting a working command as failed.
        let listing = env.runner.run("/bin/launchctl", ["print-disabled", domain], timeout: 15).output
        let recorded = parseDisabledList(listing)[label]
        let formatRecognized = listing.contains("=>")
        let verified = enabled ? recorded != true : (recorded == true || !formatRecognized)
        guard verified else {
            return StartupActionResult(success: false, message: "launchctl accepted the command, but launchd still lists \(item.name) as \(enabled ? "disabled" : "enabled").")
        }
        let unchecked = recorded == nil && !enabled && !formatRecognized ? " (launchctl's answer could not be double-checked)" : ""
        let text = enabled
            ? "\(item.name) is on again. It starts at your next login."
            : "\(item.name) is off\(stoppedNow ? " and was stopped" : ""). It will not start at your next login.\(unchecked)"
        return StartupActionResult(success: true, message: text)
    }

    private static func removeLoginItem(_ item: StartupItem, _ env: StartupEnvironment) -> StartupActionResult {
        let r = env.runner.run("/usr/bin/osascript", osascriptArguments(removeLoginItemScript, [item.name]), timeout: 120)
        guard r.status == 0 else {
            return StartupActionResult(success: false, message: friendlyAppleScriptError(r.error).text)
        }
        var remembered = StartupStore.load(env.storePath)
        let path = item.programPath ?? ""
        remembered.removeAll { $0.path == path }
        remembered.append(RemovedLoginItem(name: item.name, path: path, hidden: item.loginItemHidden, removedAt: Date()))
        do {
            try StartupStore.save(remembered, to: env.storePath)
        } catch {
            return StartupActionResult(success: true, message: "\(item.name) removed from the Login Items. CZ.commander could not remember it, so add it back in System Settings if you want it again.")
        }
        return StartupActionResult(success: true, message: "\(item.name) removed from the Login Items. Turn it on here to add it back.")
    }

    private static func restoreLoginItem(_ item: StartupItem, _ env: StartupEnvironment) -> StartupActionResult {
        guard item.removedByUs, let path = item.programPath, !path.isEmpty else {
            return StartupActionResult(success: false, message: "Only items turned off here can be added back from here.")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return StartupActionResult(success: false, message: "\(path) does not exist any more, so it cannot be added back.")
        }
        let r = env.runner.run("/usr/bin/osascript",
                               osascriptArguments(addLoginItemScript, [path, item.loginItemHidden ? "true" : "false"]), timeout: 120)
        guard r.status == 0 else {
            return StartupActionResult(success: false, message: friendlyAppleScriptError(r.error).text)
        }
        var remembered = StartupStore.load(env.storePath)
        remembered.removeAll { $0.path == path }
        try? StartupStore.save(remembered, to: env.storePath)
        return StartupActionResult(success: true, message: "\(item.name) is on again. It opens at your next login.")
    }
}
