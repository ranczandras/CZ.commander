import XCTest
@testable import CZCommanderCore

/// Plays launchctl and System Events: keeps the "disabled" set and the login item list in memory
/// and records every command, so tests see both what was asked and what the Mac would answer.
final class FakeStartupRunner: StartupCommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    private var disabled: [String: [String: Bool]] = [:]       // domain -> label -> disabled
    var running: [String: Int] = [:]                           // label -> pid
    var loginItems: [(name: String, path: String, hidden: Bool)] = []
    var failLaunchctl: Set<String> = []                        // sub-commands that fail
    var automationDenied = false
    /// `disable` is accepted but not recorded (simulates a Mac that ignores it).
    var ignoreDisable = false

    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return _calls }

    func setDisabled(_ domain: String, _ label: String, _ value: Bool) {
        lock.lock(); disabled[domain, default: [:]][label] = value; lock.unlock()
    }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> StartupCommandResult {
        lock.lock(); defer { lock.unlock() }
        _calls.append([executable] + arguments)
        if executable == "/bin/launchctl" {
            guard let sub = arguments.first else { return StartupCommandResult(status: 64) }
            if failLaunchctl.contains(sub) {
                return StartupCommandResult(status: 1, error: "Boot-out failed: 5: Input/output error")
            }
            switch sub {
            case "print-disabled":
                let domain = arguments.dropFirst().first ?? ""
                var text = "disabled services = {\n"
                for (label, off) in disabled[domain] ?? [:] { text += "\t\"\(label)\" => \(off ? "disabled" : "enabled")\n" }
                return StartupCommandResult(status: 0, output: text + "}\n")
            case "list":
                var text = "PID\tStatus\tLabel\n"
                for (label, pid) in running { text += "\(pid < 0 ? "-" : String(pid))\t0\t\(label)\n" }
                return StartupCommandResult(status: 0, output: text)
            case "disable", "enable":
                let target = arguments[1]
                let parts = target.split(separator: "/", maxSplits: 2).map(String.init)    // gui, uid, label
                let domain = parts[0] + "/" + parts[1]
                if !(sub == "disable" && ignoreDisable) { disabled[domain, default: [:]][parts[2]] = (sub == "disable") }
                return StartupCommandResult(status: 0)
            case "bootout":
                let label = arguments[1].split(separator: "/").last.map(String.init) ?? ""
                if running.removeValue(forKey: label) != nil { return StartupCommandResult(status: 0) }
                return StartupCommandResult(status: 113, error: "Could not find service")
            default:
                return StartupCommandResult(status: 64)
            }
        }
        if executable == "/usr/bin/osascript" {
            if automationDenied {
                return StartupCommandResult(status: 1, error: "execution error: Not authorized to send Apple events to System Events. (-1743)")
            }
            var lines: [String] = []
            var index = 0
            while index + 1 < arguments.count, arguments[index] == "-e" { lines.append(arguments[index + 1]); index += 2 }
            let script = lines.joined(separator: "\n")
            let args = Array(arguments[index...])
            if script.contains("repeat with li") {
                let text = loginItems.map { "\($0.name)\t\($0.path)\t\($0.hidden)\n" }.joined()
                return StartupCommandResult(status: 0, output: text)
            }
            if script.contains("delete (every login item") {
                loginItems.removeAll { $0.name == args[0] }
                return StartupCommandResult(status: 0)
            }
            if script.contains("make login item") {
                let name = ((args[0] as NSString).lastPathComponent as NSString).deletingPathExtension
                loginItems.append((name: name, path: args[0], hidden: args[1] == "true"))
                return StartupCommandResult(status: 0)
            }
        }
        return StartupCommandResult(status: 127, error: "unexpected command")
    }
}

final class StartupEngineTests: XCTestCase {
    private var root: String!
    private var runner: FakeStartupRunner!
    private var env: StartupEnvironment!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        let base = (NSTemporaryDirectory() as NSString).appendingPathComponent("cz_startup_\(UUID().uuidString)")
        try fm.createDirectory(atPath: base, withIntermediateDirectories: true)
        root = base
        runner = FakeStartupRunner()
        env = StartupEnvironment(home: root + "/home", systemRoot: root + "/sys", userID: 501, runner: runner)
        for dir in ["home/Library/LaunchAgents", "sys/Library/LaunchAgents", "sys/Library/LaunchDaemons", "apps"] {
            try fm.createDirectory(atPath: root + "/" + dir, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(atPath: root) }
    }

    @discardableResult
    private func plist(_ relative: String, _ dict: [String: Any]) throws -> String {
        let path = root + "/" + relative
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    /// A fake app bundle with its main executable, so "program exists" checks pass.
    private func makeApp(_ name: String) throws -> String {
        let exe = root + "/apps/\(name).app/Contents/MacOS/\(name)"
        try fm.createDirectory(atPath: (exe as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        _ = fm.createFile(atPath: exe, contents: Data("#!/bin/sh\n".utf8))
        return exe
    }

    private func item(_ result: StartupScanResult, label: String) throws -> StartupItem {
        try XCTUnwrap(result.items.first { $0.label == label }, "no item \(label)")
    }

    // MARK: Parsing

    func testParsesBothPrintDisabledFormats() {
        let modern = """
        disabled services = {
        \t"com.a.one" => disabled
        \t"com.a.two" => enabled
        }
        """
        let legacy = "{\n\t\"com.b.one\" => true;\n\t\"com.b.two\" => false;\n}"
        XCTAssertEqual(StartupEngine.parseDisabledList(modern), ["com.a.one": true, "com.a.two": false])
        XCTAssertEqual(StartupEngine.parseDisabledList(legacy), ["com.b.one": true, "com.b.two": false])
        XCTAssertEqual(StartupEngine.parseDisabledList("garbage\n=> disabled"), [:])
    }

    func testParsesLaunchctlListAndLoginItems() {
        let list = "PID\tStatus\tLabel\n501\t0\tcom.run.ning\n-\t78\tcom.idle.job\n"
        XCTAssertEqual(StartupEngine.parseLaunchctlList(list), ["com.run.ning": 501, "com.idle.job": -1])
        let items = StartupEngine.parseLoginItems("Dropbox\t/Applications/Dropbox.app\tfalse\nBroken\tmissing value\ttrue\n\n")
        XCTAssertEqual(items.map(\.name), ["Dropbox", "Broken"])
        XCTAssertEqual(items[1].path, "")
        XCTAssertTrue(items[1].hidden)
    }

    func testLabelValidationAndProgramDetection() {
        XCTAssertTrue(StartupEngine.isValidLabel("com.vendor.app-helper_2+x"))
        for bad in ["", "-rf", "a b", "a/b", "a;b", "../x", "x\"y", String(repeating: "a", count: 201)] {
            XCTAssertFalse(StartupEngine.isValidLabel(bad), bad)
        }
        XCTAssertEqual(StartupEngine.programPath(from: ["Program": "/opt/x/bin"]), "/opt/x/bin")
        XCTAssertEqual(StartupEngine.programPath(from: ["ProgramArguments": ["/opt/x/bin", "-d"]]), "/opt/x/bin")
        XCTAssertEqual(StartupEngine.programPath(from: ["ProgramArguments": ["/bin/sh", "-c", "echo"]]), nil)
        XCTAssertEqual(StartupEngine.programPath(from: ["ProgramArguments": ["/bin/bash", "/opt/x/run.sh"]]), "/opt/x/run.sh")
        XCTAssertEqual(StartupEngine.enclosingApp(of: "/Applications/Dropbox.app/Contents/MacOS/Dropbox"), "/Applications/Dropbox.app")
        XCTAssertNil(StartupEngine.enclosingApp(of: "/usr/local/bin/tool"))
    }

    func testTriggerClassification() {
        XCTAssertEqual(StartupEngine.classify(["RunAtLoad": true]).trigger, .atLogin)
        let keep = StartupEngine.classify(["KeepAlive": true])
        XCTAssertEqual(keep.trigger, .atLogin)
        XCTAssertTrue(keep.keepsRunning)
        XCTAssertEqual(StartupEngine.classify(["StartInterval": 3600]).trigger, .scheduled)
        XCTAssertEqual(StartupEngine.classify(["WatchPaths": ["/tmp"]]).trigger, .onEvent)
        XCTAssertEqual(StartupEngine.classify(["KeepAlive": ["PathState": ["/tmp/x": true]]]).trigger, .onEvent)
        XCTAssertEqual(StartupEngine.classify(["MachServices": ["com.x": true]]).trigger, .onDemand)
        XCTAssertEqual(StartupEngine.classify(["RunAtLoad": false]).trigger, .onDemand)
    }

    // MARK: Scan

    func testScanListsAgentsWithStateAndFlags() throws {
        let dropbox = try makeApp("Dropbox")
        try plist("home/Library/LaunchAgents/com.dropbox.agent.plist",
                  ["Label": "com.dropbox.agent", "ProgramArguments": [dropbox, "--minimized"], "RunAtLoad": true])
        try plist("home/Library/LaunchAgents/com.gone.helper.plist",
                  ["Label": "com.gone.helper", "Program": root + "/apps/Gone.app/Contents/MacOS/Gone", "RunAtLoad": true])
        try plist("home/Library/LaunchAgents/com.vendor.sleeper.plist",
                  ["Label": "com.vendor.sleeper", "Program": dropbox, "Disabled": true, "RunAtLoad": true])
        try plist("home/Library/LaunchAgents/com.vendor.override.plist",
                  ["Label": "com.vendor.override", "Program": dropbox, "RunAtLoad": true])
        try plist("home/Library/LaunchAgents/com.vendor.helper.plist",
                  ["Label": "com.vendor.helper", "Program": dropbox, "MachServices": ["com.vendor.helper": true]])
        try plist("sys/Library/LaunchAgents/com.crowdstrike.userdaemon.plist",
                  ["Label": "com.crowdstrike.userdaemon", "Program": dropbox, "RunAtLoad": true])
        try plist("sys/Library/LaunchAgents/com.apple.something.plist",
                  ["Label": "com.apple.something", "Program": "/System/Library/x", "RunAtLoad": true])
        try plist("sys/Library/LaunchDaemons/com.vendor.rootd.plist",
                  ["Label": "com.vendor.rootd", "Program": dropbox, "RunAtLoad": true])
        try "not a plist".write(toFile: root + "/home/Library/LaunchAgents/broken.plist", atomically: true, encoding: .utf8)
        try "x".write(toFile: root + "/home/Library/LaunchAgents/readme.txt", atomically: true, encoding: .utf8)
        runner.running["com.dropbox.agent"] = 4711
        runner.setDisabled("gui/501", "com.vendor.override", true)
        runner.setDisabled("gui/501", "com.vendor.sleeper", false)   // override beats the plist's Disabled key

        let result = StartupEngine.scan(environment: env)
        let dropboxItem = try item(result, label: "com.dropbox.agent")
        XCTAssertEqual(dropboxItem.name, "Dropbox", "The app name is shown instead of the label")
        XCTAssertEqual(dropboxItem.kind, .userAgent)
        XCTAssertEqual(dropboxItem.runState, .running)
        XCTAssertTrue(dropboxItem.enabled)
        XCTAssertEqual(dropboxItem.trigger, .atLogin)
        XCTAssertFalse(dropboxItem.programMissing)
        XCTAssertTrue(dropboxItem.canToggle)
        XCTAssertEqual(dropboxItem.appPath, root + "/apps/Dropbox.app")

        XCTAssertTrue(try item(result, label: "com.gone.helper").programMissing, "Program of an uninstalled app is flagged")
        XCTAssertTrue(try item(result, label: "com.vendor.sleeper").enabled, "launchd's override wins over the plist")
        XCTAssertFalse(try item(result, label: "com.vendor.override").enabled)
        XCTAssertEqual(try item(result, label: "com.vendor.helper").trigger, .onDemand)

        let security = try item(result, label: "com.crowdstrike.userdaemon")
        XCTAssertEqual(security.kind, .systemAgent)
        XCTAssertNotNil(security.cautionReason)
        XCTAssertNil(dropboxItem.cautionReason)

        let apple = try item(result, label: "com.apple.something")
        XCTAssertTrue(apple.isApple)
        XCTAssertFalse(apple.canToggle)

        let daemon = try item(result, label: "com.vendor.rootd")
        XCTAssertEqual(daemon.kind, .systemDaemon)
        XCTAssertFalse(daemon.canToggle)
        XCTAssertEqual(daemon.runState, .unknown)

        XCTAssertEqual(result.unreadablePlists, [root + "/home/Library/LaunchAgents/broken.plist"])
        XCTAssertNil(result.loginItemsError)
        // Login items come first, then user agents, at-login before on-demand.
        let kinds = result.items.map(\.kind)
        XCTAssertEqual(kinds, kinds.sorted { StartupItemKind.allCases.firstIndex(of: $0)! < StartupItemKind.allCases.firstIndex(of: $1)! })
        let userAgents = result.items.filter { $0.kind == .userAgent }
        XCTAssertEqual(userAgents.last?.label, "com.vendor.helper")
    }

    func testScanListsLoginItems() throws {
        let app = try makeApp("Notes").replacingOccurrences(of: "/Contents/MacOS/Notes", with: "")
        runner.loginItems = [("Notes", app, false), ("Ghost", root + "/apps/Ghost.app", true)]
        let result = StartupEngine.scan(environment: env)
        let notes = try XCTUnwrap(result.items.first { $0.name == "Notes" })
        XCTAssertEqual(notes.kind, .loginItem)
        XCTAssertTrue(notes.enabled)
        XCTAssertFalse(notes.programMissing)
        XCTAssertTrue(try XCTUnwrap(result.items.first { $0.name == "Ghost" }).programMissing)
        XCTAssertTrue(try XCTUnwrap(result.items.first { $0.name == "Ghost" }).loginItemHidden)
    }

    func testAutomationDeniedIsExplained() {
        runner.automationDenied = true
        let result = StartupEngine.scan(environment: env)
        XCTAssertTrue(result.loginItemsNeedPermission)
        XCTAssertTrue(result.loginItemsError?.contains("Automation") == true)
    }

    // MARK: Agents on and off

    func testTurningAnAgentOffAndOn() throws {
        let app = try makeApp("Dropbox")
        let path = try plist("home/Library/LaunchAgents/com.dropbox.agent.plist",
                             ["Label": "com.dropbox.agent", "Program": app, "RunAtLoad": true])
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        runner.running["com.dropbox.agent"] = 4711

        var target = try item(StartupEngine.scan(environment: env), label: "com.dropbox.agent")
        let off = StartupEngine.setEnabled(target, to: false, environment: env)
        XCTAssertTrue(off.success, off.message)
        XCTAssertTrue(off.message.contains("stopped"))
        XCTAssertTrue(runner.calls.contains(["/bin/launchctl", "disable", "gui/501/com.dropbox.agent"]))
        XCTAssertTrue(runner.calls.contains(["/bin/launchctl", "bootout", "gui/501/com.dropbox.agent"]))

        target = try item(StartupEngine.scan(environment: env), label: "com.dropbox.agent")
        XCTAssertFalse(target.enabled)
        XCTAssertEqual(target.runState, .notLoaded)

        let on = StartupEngine.setEnabled(target, to: true, environment: env)
        XCTAssertTrue(on.success, on.message)
        XCTAssertTrue(try item(StartupEngine.scan(environment: env), label: "com.dropbox.agent").enabled)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original, "The plist is never modified")
    }

    func testSystemAgentIsTurnedOffForThisUserOnly() throws {
        let app = try makeApp("Updater")
        try plist("sys/Library/LaunchAgents/com.vendor.updater.plist",
                  ["Label": "com.vendor.updater", "Program": app, "RunAtLoad": true])
        let target = try item(StartupEngine.scan(environment: env), label: "com.vendor.updater")
        XCTAssertTrue(StartupEngine.setEnabled(target, to: false, environment: env).success)
        XCTAssertTrue(runner.calls.allSatisfy { !$0.contains("system") || $0.first != "/bin/launchctl" || $0.dropFirst().first == "print-disabled" },
                      "Only the gui/<uid> domain is changed, never system")
        XCTAssertFalse(try item(StartupEngine.scan(environment: env), label: "com.vendor.updater").enabled)
    }

    func testFailureAndIgnoredCommandsAreReported() throws {
        let app = try makeApp("Dropbox")
        try plist("home/Library/LaunchAgents/com.dropbox.agent.plist",
                  ["Label": "com.dropbox.agent", "Program": app, "RunAtLoad": true])
        let target = try item(StartupEngine.scan(environment: env), label: "com.dropbox.agent")

        runner.failLaunchctl = ["disable"]
        let failed = StartupEngine.setEnabled(target, to: false, environment: env)
        XCTAssertFalse(failed.success)
        XCTAssertTrue(failed.message.contains("Input/output error"))

        runner.failLaunchctl = []
        runner.ignoreDisable = true
        runner.setDisabled("gui/501", "com.other.thing", true)   // a real Mac always lists some entries
        let ignored = StartupEngine.setEnabled(target, to: false, environment: env)
        XCTAssertFalse(ignored.success, "A command that launchd did not record is not reported as success")
    }

    func testUnrecognisedPrintDisabledFormatDoesNotFailAWorkingCommand() throws {
        let app = try makeApp("Dropbox")
        try plist("home/Library/LaunchAgents/com.dropbox.agent.plist",
                  ["Label": "com.dropbox.agent", "Program": app, "RunAtLoad": true])
        let target = try item(StartupEngine.scan(environment: env), label: "com.dropbox.agent")
        // Nothing is recorded and the listing has no `"label" => state` lines at all.
        runner.ignoreDisable = true
        let result = StartupEngine.setEnabled(target, to: false, environment: env)
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.message.contains("could not be double-checked"))
    }

    func testProtectedItemsAreNeverTouched() throws {
        let app = try makeApp("X")
        try plist("sys/Library/LaunchAgents/com.apple.something.plist",
                  ["Label": "com.apple.something", "Program": "/System/Library/x", "RunAtLoad": true])
        try plist("sys/Library/LaunchDaemons/com.vendor.rootd.plist",
                  ["Label": "com.vendor.rootd", "Program": app, "RunAtLoad": true])
        try plist("home/Library/LaunchAgents/weird.plist",
                  ["Label": "evil label; rm -rf", "Program": app, "RunAtLoad": true])
        let result = StartupEngine.scan(environment: env)
        let before = runner.calls.count
        for item in result.items where item.kind != .loginItem {
            XCTAssertFalse(StartupEngine.setEnabled(item, to: false, environment: env).success, item.name)
        }
        XCTAssertEqual(runner.calls.count, before, "No command is run for a blocked item")

        // A forged item (right label, plist outside the agent folders) is refused as well.
        var forged = try item(result, label: "com.vendor.rootd")
        forged.toggleBlockedReason = nil
        forged.kind = .userAgent
        XCTAssertFalse(StartupEngine.setEnabled(forged, to: false, environment: env).success)
        XCTAssertEqual(runner.calls.count, before)
    }

    // MARK: Login items on and off

    func testLoginItemIsRemovedRememberedAndRestored() throws {
        let app = try makeApp("Notes").replacingOccurrences(of: "/Contents/MacOS/Notes", with: "")
        runner.loginItems = [("Notes", app, true), ("Other", root + "/apps/Other.app", false)]
        let target = try XCTUnwrap(StartupEngine.scan(environment: env).items.first { $0.name == "Notes" })

        let off = StartupEngine.setEnabled(target, to: false, environment: env)
        XCTAssertTrue(off.success, off.message)
        XCTAssertEqual(runner.loginItems.map(\.name), ["Other"])
        let osascript = try XCTUnwrap(runner.calls.last { $0.first == "/usr/bin/osascript" })
        XCTAssertEqual(osascript.last, "Notes", "The name travels as an argument, not inside the script")

        let rescan = StartupEngine.scan(environment: env)
        let removed = try XCTUnwrap(rescan.items.first { $0.name == "Notes" })
        XCTAssertFalse(removed.enabled)
        XCTAssertTrue(removed.removedByUs)
        XCTAssertTrue(removed.loginItemHidden, "Hidden-at-launch is remembered too")

        let on = StartupEngine.setEnabled(removed, to: true, environment: env)
        XCTAssertTrue(on.success, on.message)
        XCTAssertEqual(runner.loginItems.first { $0.name == "Notes" }?.path, app)
        XCTAssertEqual(runner.loginItems.first { $0.name == "Notes" }?.hidden, true)
        let after = StartupEngine.scan(environment: env)
        XCTAssertEqual(after.items.filter { $0.name == "Notes" }.count, 1)
        XCTAssertTrue(try XCTUnwrap(after.items.first { $0.name == "Notes" }).enabled)
        XCTAssertTrue(StartupStore.load(env.storePath).isEmpty)
    }

    func testRestoreRefusesMissingAppAndUnknownItems() throws {
        let gone = root + "/apps/Gone.app"
        try StartupStore.save([RemovedLoginItem(name: "Gone", path: gone, hidden: false, removedAt: Date())], to: env.storePath)
        let removed = try XCTUnwrap(StartupEngine.scan(environment: env).items.first { $0.name == "Gone" })
        let result = StartupEngine.setEnabled(removed, to: true, environment: env)
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.message.contains("does not exist"))

        runner.loginItems = [("Live", root + "/apps/Live.app", false)]
        let live = try XCTUnwrap(StartupEngine.scan(environment: env).items.first { $0.name == "Live" })
        XCTAssertFalse(StartupEngine.setEnabled(live, to: true, environment: env).success, "Only items removed here can be restored")
    }

    func testManuallyReAddedLoginItemForgetsTheRecord() throws {
        let app = root + "/apps/Notes.app"
        try StartupStore.save([RemovedLoginItem(name: "Notes", path: app, hidden: false, removedAt: Date())], to: env.storePath)
        runner.loginItems = [("Notes", app, false)]
        let items = StartupEngine.scan(environment: env).items.filter { $0.name == "Notes" }
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].enabled)
        XCTAssertTrue(StartupStore.load(env.storePath).isEmpty)
    }

    func testRemovedItemsAreHiddenWhenTheListCannotBeRead() throws {
        try StartupStore.save([RemovedLoginItem(name: "Notes", path: root + "/apps/Notes.app", hidden: false, removedAt: Date())], to: env.storePath)
        runner.automationDenied = true
        let result = StartupEngine.scan(environment: env)
        XCTAssertTrue(result.items.filter { $0.kind == .loginItem }.isEmpty)
        XCTAssertEqual(StartupStore.load(env.storePath).count, 1, "The memory is kept until the list can be read again")
    }

    func testCautionWords() {
        XCTAssertNotNil(StartupEngine.cautionReason(["com.jamf.management.agent"]))
        XCTAssertNotNil(StartupEngine.cautionReason(["Mullvad VPN"]))
        XCTAssertNil(StartupEngine.cautionReason(["com.dropbox.agent", "/Applications/Dropbox.app"]))
    }
}
