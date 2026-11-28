import XCTest
@testable import CZCommanderCore

final class AppUninstallEngineTests: XCTestCase {
    private var root: URL!
    private var home: String { root.appendingPathComponent("home").path }
    private var system: String { root.appendingPathComponent("sys").path }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("czc-uninst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func mkdir(_ path: String) {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    private func touch(_ path: String, _ contents: String = "x") {
        mkdir((path as NSString).deletingLastPathComponent)
        FileManager.default.createFile(atPath: path, contents: Data(contents.utf8))
    }

    private func writePlist(_ path: String, _ dict: [String: Any]) {
        mkdir((path as NSString).deletingLastPathComponent)
        (dict as NSDictionary).write(toFile: path, atomically: true)
    }

    private func makeApp() -> InstalledApp {
        let app = root.appendingPathComponent("Applications/Foo Studio.app").path
        writePlist(app + "/Contents/Info.plist", [
            "CFBundleIdentifier": "com.example.foostudio",
            "CFBundleName": "Foo Studio",
            "CFBundleExecutable": "FooStudio",
            "CFBundleShortVersionString": "2.1",
        ])
        touch(app + "/Contents/MacOS/FooStudio")
        writePlist(app + "/Contents/Library/LoginItems/FooHelper.app/Contents/Info.plist", [
            "CFBundleIdentifier": "com.example.foostudio.helper",
        ])
        writePlist(app + "/Contents/PlugIns/Share.appex/Contents/Info.plist", [
            "CFBundleIdentifier": "com.example.foostudio.share",
        ])
        return AppUninstallEngine.loadApp(at: app)!
    }

    func testLoadAppAndRelatedIDs() {
        let app = makeApp()
        XCTAssertEqual(app.name, "Foo Studio")
        XCTAssertEqual(app.bundleID, "com.example.foostudio")
        XCTAssertEqual(app.version, "2.1")
        XCTAssertNil(app.protectionReason)
        let ids = AppUninstallEngine.relatedBundleIDs(appPath: app.path, mainID: app.bundleID)
        XCTAssertEqual(Set(ids), ["com.example.foostudio", "com.example.foostudio.helper", "com.example.foostudio.share"])

        let listed = AppUninstallEngine.listApps(in: [root.appendingPathComponent("Applications").path])
        XCTAssertEqual(listed.map(\.name), ["Foo Studio"])
    }

    func testFindsLeftoversAndNothingElse() throws {
        let app = makeApp()
        let lib = home + "/Library"
        // Belongs to the app
        touch(lib + "/Application Support/Foo Studio/db.sqlite")
        touch(lib + "/Application Support/com.example.foostudio/state")
        touch(lib + "/Caches/com.example.foostudio/blob")
        touch(lib + "/Preferences/com.example.foostudio.plist")
        touch(lib + "/Preferences/com.example.foostudio.helper.plist")
        touch(lib + "/Preferences/ByHost/com.example.foostudio.ABCD-1234.plist")
        touch(lib + "/Containers/com.example.foostudio.share/Data/x")
        touch(lib + "/Group Containers/group.com.example.foostudio/x")
        touch(lib + "/Saved Application State/com.example.foostudio.savedState/windows.plist")
        touch(lib + "/HTTPStorages/com.example.foostudio/x")
        touch(lib + "/WebKit/com.example.foostudio/x")
        touch(lib + "/Logs/Foo Studio/log.txt")
        touch(lib + "/Logs/DiagnosticReports/FooStudio-2026-11-20-101010.ips")
        writePlist(lib + "/LaunchAgents/com.example.foostudio.updater.plist", [
            "Label": "com.example.foostudio.updater", "ProgramArguments": ["/x/updater"],
        ])
        writePlist(lib + "/LaunchAgents/com.other.agent.plist", [
            "Label": "com.other.agent", "Program": app.path + "/Contents/MacOS/FooStudio",
        ])
        touch(system + "/Library/PrivilegedHelperTools/com.example.foostudio.helper")
        // Vendor folder: "Example/Foo Studio"? No: vendor + product = app name.
        touch(lib + "/Application Support/Foo/Studio/prefs")

        // Must NOT be found
        touch(lib + "/Application Support/Foo Studio Pro/keep")
        touch(lib + "/Preferences/com.example.foostudiopro.plist")
        touch(lib + "/Preferences/com.apple.finder.plist")
        touch(lib + "/Caches/com.example.other/keep")
        touch(lib + "/Logs/DiagnosticReports/FooStudioPro-2026.ips")
        touch(home + "/Documents/Foo Studio/my work.txt")
        let outside = root.appendingPathComponent("elsewhere").path
        mkdir(outside)
        try FileManager.default.createSymbolicLink(atPath: lib + "/Caches/com.example.foostudio.link", withDestinationPath: outside)

        let ctx = AppUninstallEngine.SearchContext(home: home, systemRoot: system)
        let ids = AppUninstallEngine.relatedBundleIDs(appPath: app.path, mainID: app.bundleID)
        let found = AppUninstallEngine.findLeftovers(app: app, relatedIDs: ids, teamID: nil, context: ctx, measure: true)
        let paths = Set(found.map { $0.path.replacingOccurrences(of: root.path, with: "") })

        let expected: Set<String> = [
            "/home/Library/Application Support/Foo Studio",
            "/home/Library/Application Support/com.example.foostudio",
            "/home/Library/Application Support/Foo/Studio",
            "/home/Library/Caches/com.example.foostudio",
            "/home/Library/Preferences/com.example.foostudio.plist",
            "/home/Library/Preferences/com.example.foostudio.helper.plist",
            "/home/Library/Preferences/ByHost/com.example.foostudio.ABCD-1234.plist",
            "/home/Library/Containers/com.example.foostudio.share",
            "/home/Library/Group Containers/group.com.example.foostudio",
            "/home/Library/Saved Application State/com.example.foostudio.savedState",
            "/home/Library/HTTPStorages/com.example.foostudio",
            "/home/Library/WebKit/com.example.foostudio",
            "/home/Library/Logs/Foo Studio",
            "/home/Library/Logs/DiagnosticReports/FooStudio-2026-11-20-101010.ips",
            "/home/Library/LaunchAgents/com.example.foostudio.updater.plist",
            "/home/Library/LaunchAgents/com.other.agent.plist",
            "/sys/Library/PrivilegedHelperTools/com.example.foostudio.helper",
        ]
        XCTAssertEqual(paths, expected, "missing: \(expected.subtracting(paths)), extra: \(paths.subtracting(expected))")

        let agent = found.first { $0.path.hasSuffix("com.example.foostudio.updater.plist") }
        XCTAssertEqual(agent?.launchLabel, "com.example.foostudio.updater")
        XCTAssertEqual(found.first { $0.path.hasSuffix("PrivilegedHelperTools/com.example.foostudio.helper") }?.needsAdmin, true)
        XCTAssertTrue(found.allSatisfy { $0.preselected }, "\(found.filter { !$0.preselected }.map(\.path))")
        XCTAssertGreaterThan(found.first { $0.path.hasSuffix("/Caches/com.example.foostudio") }?.sizeBytes ?? 0, 0)
    }

    func testPrefixAndSharedComponentMatchesAreNotPreselected() {
        let app = makeApp()
        // A bundled updater that is not under the app's own id (shared by the vendor's apps).
        writePlist(app.path + "/Contents/Helpers/Updater.app/Contents/Info.plist", ["CFBundleIdentifier": "com.example.updater"])
        let lib = home + "/Library"
        touch(lib + "/Caches/com.example.updater/x")
        touch(lib + "/Caches/com.example.foostudio.remote_thing/x")
        writePlist(lib + "/LaunchAgents/com.example.updater.wake.plist", ["Label": "com.example.updater.wake"])
        touch(lib + "/Caches/com.example.foostudio/x")
        let ctx = AppUninstallEngine.SearchContext(home: home, systemRoot: system)
        let ids = AppUninstallEngine.relatedBundleIDs(appPath: app.path, mainID: app.bundleID)
        XCTAssertTrue(ids.contains("com.example.updater"))
        let found = AppUninstallEngine.findLeftovers(app: app, relatedIDs: ids, teamID: nil, context: ctx, measure: false)
        func item(_ suffix: String) -> AppLeftover? { found.first { $0.path.hasSuffix(suffix) } }
        XCTAssertEqual(item("/Caches/com.example.foostudio")?.preselected, true)
        XCTAssertEqual(item("/Caches/com.example.updater")?.preselected, false)
        XCTAssertEqual(item("/Caches/com.example.updater")?.match, .related)
        XCTAssertEqual(item("/Caches/com.example.foostudio.remote_thing")?.preselected, false)
        XCTAssertEqual(item("/LaunchAgents/com.example.updater.wake.plist")?.preselected, false)
    }

    func testTeamGroupContainerIsNotPreselected() {
        let app = makeApp()
        touch(home + "/Library/Group Containers/ABCDE12345.foostudio/x")
        touch(home + "/Library/Group Containers/ABCDE12345.office/x")
        let ctx = AppUninstallEngine.SearchContext(home: home, systemRoot: system)
        let found = AppUninstallEngine.findLeftovers(app: app, relatedIDs: [app.bundleID!], teamID: "ABCDE12345", context: ctx, measure: false)
        XCTAssertEqual(found.map { ($0.path as NSString).lastPathComponent }, ["ABCDE12345.foostudio"])
        XCTAssertEqual(found.first?.preselected, false)
        XCTAssertEqual(found.first?.match, .team)
    }

    func testSafetyRules() {
        let ctx = AppUninstallEngine.SearchContext(home: "/Users/u", systemRoot: "")
        XCTAssertTrue(AppUninstallEngine.isSafeLeftover("/Users/u/Library/Caches/com.x.y", context: ctx))
        XCTAssertTrue(AppUninstallEngine.isSafeLeftover("/Users/u/Library/Application Support/Google/Chrome", context: ctx))
        XCTAssertFalse(AppUninstallEngine.isSafeLeftover("/Users/u/Library/Caches", context: ctx))
        XCTAssertFalse(AppUninstallEngine.isSafeLeftover("/Users/u/Library/Preferences/a/b.plist", context: ctx))
        XCTAssertFalse(AppUninstallEngine.isSafeLeftover("/Users/u/Documents/thing", context: ctx))
        XCTAssertFalse(AppUninstallEngine.isSafeLeftover("/Users/u/Library/Caches/../Mail", context: ctx))
        XCTAssertFalse(AppUninstallEngine.isSafeLeftover("/Library/Application Support/a/b/c", context: ctx))
        XCTAssertTrue(AppUninstallEngine.isSafeLeftover("/Library/LaunchDaemons/com.x.helper.plist", context: ctx))

        XCTAssertNotNil(AppUninstallEngine.protectionReason(path: "/System/Applications/Mail.app", bundleID: "com.apple.mail"))
        // App Store apps from Apple are removable; only SIP-flagged ones are not.
        XCTAssertNil(AppUninstallEngine.protectionReason(path: "/Applications/GarageBand.app", bundleID: "com.apple.garageband10"))
        if FileManager.default.fileExists(atPath: "/Applications/Safari.app") {
            XCTAssertNotNil(AppUninstallEngine.protectionReason(path: "/Applications/Safari.app", bundleID: "com.apple.Safari"))
        }
        XCTAssertTrue(AppUninstallEngine.isPermissionError(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)))
        XCTAssertTrue(AppUninstallEngine.isPermissionError(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))))
        XCTAssertFalse(AppUninstallEngine.isPermissionError(NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)))
        XCTAssertNotNil(AppUninstallEngine.protectionReason(path: "/Applications/CZ.commander.app", bundleID: "com.czcommander.macos"))
        XCTAssertNil(AppUninstallEngine.protectionReason(path: "/Applications/Foo.app", bundleID: "com.example.foo"))
    }
}

final class AppUninstallVendorTests: XCTestCase {
    func testVendorUninstallerNextToApp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("czc-vendor-\(UUID().uuidString)/Foo 2026")
        try FileManager.default.createDirectory(atPath: dir.path + "/Foo 2026.app/Contents", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dir.path + "/Uninstall Foo 2026.app/Contents", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        XCTAssertEqual(AppUninstallEngine.vendorUninstaller(for: dir.path + "/Foo 2026.app"), dir.path + "/Uninstall Foo 2026.app")
        XCTAssertNil(AppUninstallEngine.vendorUninstaller(for: "/Applications/Safari.app"))
    }
}
