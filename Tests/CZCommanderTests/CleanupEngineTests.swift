import XCTest
@testable import CZCommanderCore

/// Cleanup runs against a throw-away folder that plays the role of the home folder, the
/// per-user temp folder and the system root, so no test ever touches real user files.
final class CleanupEngineTests: XCTestCase {
    private var root: String!
    private var env: CleanupEnvironment!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        let base = (NSTemporaryDirectory() as NSString).appendingPathComponent("cz_cleanup_\(UUID().uuidString)")
        try fm.createDirectory(atPath: base, withIntermediateDirectories: true)
        // Work with the real path so symlinked temp folders (/var -> /private/var) do not get in the way.
        root = CleanupFS.realPath(base) ?? base
        env = CleanupEnvironment(home: root + "/home", tempDirectory: root + "/tmp/T", systemRoot: root + "/sys",
                                 now: Date(), runningBundleIDs: [])
        for dir in ["home/Library/Caches", "home/Library/Logs", "home/Documents", "home/.Trash", "tmp/T", "sys/Volumes"] {
            try fm.createDirectory(atPath: root + "/" + dir, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        if let root {
            // Tests create read-only folders on purpose.
            _ = try? fm.subpathsOfDirectory(atPath: root).map { chmod(root + "/" + $0, 0o700) }
            try? fm.removeItem(atPath: root)
        }
    }

    @discardableResult
    private func write(_ relative: String, bytes: Int = 1000) throws -> String {
        let path = root + "/" + relative
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        XCTAssertTrue(fm.createFile(atPath: path, contents: Data(repeating: 0x41, count: bytes)))
        return path
    }

    private func exists(_ relative: String) -> Bool { CleanupFS.exists(root + "/" + relative) }

    private func age(_ relative: String, days: Double) throws {
        let date = Date().addingTimeInterval(-days * 86_400)
        let path = root + "/" + relative
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    private var cachesRule: CleanupRule {
        CleanupRule(id: "caches", category: .appCaches, title: "Caches", detail: "",
                    targets: [.contents(env.homePath("Library/Caches"))])
    }

    // MARK: Patterns

    func testWildcardAndPatternMatching() {
        XCTAssertTrue(CleanupPath.wildcardMatch("*", "anything"))
        XCTAssertTrue(CleanupPath.wildcardMatch("Install macOS *.app", "Install macOS Sonoma.app"))
        XCTAssertFalse(CleanupPath.wildcardMatch("Install macOS *.app", "Install macOS Sonoma.dmg"))
        XCTAssertTrue(CleanupPath.wildcardMatch("a*b*c", "a--b--c"))
        XCTAssertFalse(CleanupPath.wildcardMatch("a*b*c", "a--b--"))
        XCTAssertTrue(CleanupPath.matches(pattern: "/h/Library/Containers/*/Data/Library/Caches",
                                          path: "/h/Library/Containers/com.app/Data/Library/Caches"))
        // A wildcard never spans a path separator, and the depth must be equal.
        XCTAssertFalse(CleanupPath.matches(pattern: "/h/Library/Caches/*", path: "/h/Library/Caches/a/b"))
        XCTAssertFalse(CleanupPath.matches(pattern: "/h/Library/Caches/*", path: "/h/Library/Caches"))
        XCTAssertEqual(CleanupPath.normalize("//a///b/"), "/a/b")
        XCTAssertFalse(CleanupPath.isCanonicalForm("/a/../b"))
        XCTAssertFalse(CleanupPath.isCanonicalForm("relative/path"))
    }

    // MARK: Scan

    func testScanGroupsItemsWithSizesAndPreselection() throws {
        try write("home/Library/Caches/com.big.app/data.bin", bytes: 50_000)
        try write("home/Library/Caches/com.big.app/sub/more.bin", bytes: 10_000)
        try write("home/Library/Caches/com.small.app/x", bytes: 2_000)
        try write("home/Library/Logs/app.log", bytes: 3_000)
        try write("home/.Trash/old.txt", bytes: 500)
        try fm.createDirectory(atPath: root + "/home/Library/Caches/empty.app", withIntermediateDirectories: true)

        let logs = CleanupRule(id: "logs", category: .logs, title: "Logs", detail: "", risk: .caution,
                               targets: [.contents(env.homePath("Library/Logs"))])
        let result = CleanupEngine.scan(environment: env, rules: CleanupCatalog.trashRules(for: env) + [cachesRule, logs])

        XCTAssertEqual(result.categories.map(\.category), [.trash, .appCaches, .logs], "Categories keep their fixed order")
        let caches = try XCTUnwrap(result.categories.first { $0.category == .appCaches }?.groups.first)
        XCTAssertEqual(caches.items.map(\.displayName), ["com.big.app", "com.small.app"], "Largest first, empty folders are not listed")
        XCTAssertEqual(caches.items[0].logicalBytes, 60_000)
        XCTAssertEqual(caches.items[0].fileCount, 2)
        XCTAssertGreaterThan(caches.items[0].sizeBytes, 0)
        XCTAssertTrue(caches.items.allSatisfy(\.preselected), "Safe items are ticked by default")
        let logItems = result.allItems.filter { $0.category == .logs }
        XCTAssertEqual(logItems.count, 1)
        XCTAssertFalse(logItems[0].preselected, "Caution items are never ticked by default")
        XCTAssertEqual(result.totalBytes, result.allItems.reduce(0) { $0 + $1.sizeBytes })
        XCTAssertTrue(exists("home/Library/Caches/com.big.app/data.bin"), "Scanning never deletes")
    }

    func testGenericRuleLeavesFoldersOfSpecificRulesAlone() throws {
        try write("home/Library/Caches/Google/Chrome/Default/Cache/f", bytes: 4_000)
        try write("home/Library/Caches/Google/Other/f", bytes: 4_000)
        try write("home/Library/Caches/com.other/f", bytes: 4_000)
        let chrome = CleanupRule(id: "chrome", category: .browserCaches, title: "Chrome", detail: "",
                                 targets: [.item(env.homePath("Library/Caches/Google/Chrome"))])
        let result = CleanupEngine.scan(environment: env, rules: [cachesRule, chrome])
        let paths = Set(result.allItems.map(\.path))
        XCTAssertEqual(paths, [env.homePath("Library/Caches/Google/Chrome"), env.homePath("Library/Caches/com.other")],
                       "The folder holding another rule's target is not listed by the generic rule")
        XCTAssertEqual(result.allItems.first { $0.ruleID == "chrome" }?.category, .browserCaches)
    }

    func testExclusionsAndExtensionFilter() throws {
        try write("home/Library/Caches/com.apple.bird/db", bytes: 4_000)
        try write("home/Library/Caches/CloudKit/db", bytes: 4_000)
        try write("home/Library/Caches/com.vendor.app/db", bytes: 4_000)
        try write("home/Downloads/setup.DMG", bytes: 4_000)
        try write("home/Downloads/thesis.pdf", bytes: 4_000)
        let caches = CleanupRule(id: "caches", category: .appCaches, title: "", detail: "",
                                 targets: [.contents(env.homePath("Library/Caches"))],
                                 excludedNames: ["CloudKit"], excludedPrefixes: ["com.apple."])
        let installers = CleanupRule(id: "dmg", category: .largeLeftovers, title: "", detail: "", risk: .caution,
                                     targets: [.contents(env.homePath("Downloads"))], allowedExtensions: ["dmg", "pkg"])
        let result = CleanupEngine.scan(environment: env, rules: [caches, installers])
        XCTAssertEqual(result.allItems.map(\.displayName).sorted(), ["com.vendor.app", "setup.DMG"])
        // The filter is part of the allowlist too: a forged item for the PDF is refused.
        let pdf = env.homePath("Downloads/thesis.pdf")
        XCTAssertNotNil(CleanupSafety(environment: env).refusalReason(path: pdf, rule: installers))
    }

    func testAgeLimitSkipsRecentlyUsedItems() throws {
        try write("tmp/T/fresh/file", bytes: 4_000)
        try write("tmp/T/stale/file", bytes: 4_000)
        try write("tmp/T/stale-outside-fresh-inside/file", bytes: 4_000)
        try age("tmp/T/stale/file", days: 10)
        try age("tmp/T/stale", days: 10)
        try age("tmp/T/stale-outside-fresh-inside", days: 10)
        let temp = CleanupRule(id: "tmp", category: .tempFiles, title: "", detail: "",
                               targets: [.contents(env.tempDirectory)], minAgeDays: 3)
        let result = CleanupEngine.scan(environment: env, rules: [temp])
        XCTAssertEqual(result.allItems.map(\.displayName), ["stale"], "The newest file anywhere inside decides the age")
    }

    func testRunningAppIsListedButNotPreselected() throws {
        try write("home/Library/Caches/com.Vendor.Running/f", bytes: 4_000)
        try write("home/Library/Caches/com.vendor.idle/f", bytes: 4_000)
        try write("home/Library/Caches/BrowserStuff/f", bytes: 4_000)
        env.runningBundleIDs = ["com.vendor.running", "com.browser.app"]
        let browser = CleanupRule(id: "browser", category: .browserCaches, title: "", detail: "",
                                  targets: [.item(env.homePath("Library/Caches/BrowserStuff"))], bundleIDs: ["com.Browser.App"])
        let result = CleanupEngine.scan(environment: env, rules: [cachesRule, browser])
        let byName = Dictionary(uniqueKeysWithValues: result.allItems.map { ($0.displayName, $0) })
        XCTAssertEqual(byName["com.Vendor.Running"]?.ownerRunning, true)
        XCTAssertEqual(byName["com.Vendor.Running"]?.preselected, false)
        XCTAssertEqual(byName["com.vendor.idle"]?.preselected, true)
        XCTAssertEqual(byName["BrowserStuff"]?.preselected, false)
    }

    func testFoldersWithSocketsOrPipesAreSkipped() throws {
        try write("tmp/T/in-use/data", bytes: 4_000)
        XCTAssertEqual(mkfifo(root + "/tmp/T/in-use/pipe", 0o600), 0)
        try write("tmp/T/idle/data", bytes: 4_000)
        let temp = CleanupRule(id: "tmp", category: .tempFiles, title: "", detail: "", targets: [.contents(env.tempDirectory)])
        let result = CleanupEngine.scan(environment: env, rules: [temp])
        XCTAssertEqual(result.allItems.map(\.displayName), ["idle"])
    }

    func testHardLinksAreCountedOnce() throws {
        let original = try write("home/Library/Caches/store/blob", bytes: 20_000)
        try fm.createDirectory(atPath: root + "/home/Library/Caches/other", withIntermediateDirectories: true)
        XCTAssertEqual(link(original, root + "/home/Library/Caches/other/blob"), 0)
        let result = CleanupEngine.scan(environment: env, rules: [cachesRule])
        XCTAssertEqual(result.allItems.reduce(0) { $0 + $1.logicalBytes }, 20_000)
    }

    func testCancelledScanReportsIt() throws {
        try write("home/Library/Caches/a/f")
        let cancel = CleanupCancellation()
        cancel.cancel()
        let result = CleanupEngine.scan(environment: env, rules: [cachesRule], cancellation: cancel)
        XCTAssertTrue(result.wasCancelled)
        XCTAssertTrue(result.allItems.isEmpty)
    }

    // MARK: Delete

    func testDeleteRemovesOnlyTheChosenItems() throws {
        try write("home/Library/Caches/doomed/a/b/c.bin", bytes: 30_000)
        try write("home/Library/Caches/keeper/data.bin", bytes: 30_000)
        let rules = [cachesRule]
        let items = CleanupEngine.scan(environment: env, rules: rules).allItems
        let doomed = items.filter { $0.displayName == "doomed" }
        let report = CleanupEngine.delete(items: doomed, environment: env, rules: rules)
        XCTAssertEqual(report.deletedPaths, [env.homePath("Library/Caches/doomed")])
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertGreaterThanOrEqual(report.freedBytes, 30_000)
        XCTAssertFalse(exists("home/Library/Caches/doomed"))
        XCTAssertTrue(exists("home/Library/Caches/keeper/data.bin"))
        XCTAssertTrue(exists("home/Library/Caches"), "The scanned folder itself stays")
    }

    func testKeepRootEmptiesTheFolderButKeepsIt() throws {
        try write("home/Library/Containers/com.app/Data/Library/Caches/x/y.bin", bytes: 9_000)
        try write("home/Library/Containers/com.app/Data/Library/Caches/z.bin", bytes: 9_000)
        try write("home/Library/Containers/com.app/Data/Documents/precious.txt")
        let rule = CleanupRule(id: "containers", category: .appCaches, title: "", detail: "",
                               targets: [.item(env.homePath("Library/Containers/*/Data/Library/Caches"))], keepRoot: true)
        let items = CleanupEngine.scan(environment: env, rules: [rule]).allItems
        XCTAssertEqual(items.map(\.displayName), ["com.app – Caches"])
        let report = CleanupEngine.delete(items: items, environment: env, rules: [rule])
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertTrue(exists("home/Library/Containers/com.app/Data/Library/Caches"))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root + "/home/Library/Containers/com.app/Data/Library/Caches"), [])
        XCTAssertTrue(exists("home/Library/Containers/com.app/Data/Documents/precious.txt"))
        XCTAssertTrue(CleanupEngine.scan(environment: env, rules: [rule]).allItems.isEmpty, "An emptied folder is not offered again")
    }

    func testReadOnlyTreesAreRemoved() throws {
        try write("home/Library/Caches/gomod/pkg/file.go", bytes: 4_000)
        XCTAssertEqual(chmod(root + "/home/Library/Caches/gomod/pkg/file.go", 0o400), 0)
        XCTAssertEqual(chmod(root + "/home/Library/Caches/gomod/pkg", 0o500), 0)
        XCTAssertEqual(chmod(root + "/home/Library/Caches/gomod", 0o500), 0)
        let items = CleanupEngine.scan(environment: env, rules: [cachesRule]).allItems
        let report = CleanupEngine.delete(items: items, environment: env, rules: [cachesRule])
        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)")
        XCTAssertFalse(exists("home/Library/Caches/gomod"))
    }

    func testEmptyTrashRemovesLinksButNeverTheirTargets() throws {
        try write("home/Documents/thesis.txt", bytes: 5_000)
        try write("home/.Trash/junk/a.bin", bytes: 5_000)
        try write("home/.Trash/.DS_Store", bytes: 100)
        try fm.createSymbolicLink(atPath: root + "/home/.Trash/Documents alias", withDestinationPath: root + "/home/Documents")
        try write("sys/Volumes/USB/.Trashes/\(env.userID)/movie.mov", bytes: 5_000)
        try write("sys/Volumes/USB/.Trashes/99999/someone-elses.mov", bytes: 5_000)
        try write("sys/Volumes/USB/keep.mov", bytes: 5_000)

        let summary = CleanupEngine.trashSummary(environment: env)
        XCTAssertEqual(summary.itemCount, 4, "junk, .DS_Store, the alias and the file on the USB drive")
        XCTAssertFalse(summary.homeTrashUnreadable)

        let report = CleanupEngine.emptyTrash(environment: env)
        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root + "/home/.Trash"), [])
        XCTAssertTrue(exists("home/Documents/thesis.txt"), "A symlink in the Trash is removed as a link")
        XCTAssertTrue(exists("sys/Volumes/USB/.Trashes/99999/someone-elses.mov"))
        XCTAssertTrue(exists("sys/Volumes/USB/keep.mov"))
        XCTAssertFalse(exists("sys/Volumes/USB/.Trashes/\(env.userID)/movie.mov"))
        XCTAssertEqual(CleanupEngine.trashSummary(environment: env).itemCount, 0)
    }

    // MARK: Safety

    func testForgedItemsAreRefused() throws {
        let precious = try write("home/Documents/thesis.txt")
        let sneaky = try write("home/Library/Caches/app/../../../Documents/second.txt")
        let rules = CleanupCatalog.trashRules(for: env) + [cachesRule]
        func forged(_ path: String, rule: String) -> CleanupItem {
            CleanupItem(path: path, displayName: "x", ruleID: rule, category: .trash, sizeBytes: 1, logicalBytes: 1,
                        fileCount: 1, newestModification: nil, isDirectory: false, ownerRunning: false, preselected: true)
        }
        let report = CleanupEngine.delete(items: [
            forged(precious, rule: "trash.home"),                                        // not inside the rule's folder
            forged(env.homePath("Library/Caches/app/../../../Documents/second.txt"), rule: "caches"),  // climbs out with ..
            forged(env.homePath("Library/Caches"), rule: "caches"),                      // the folder itself
            forged(env.home, rule: "caches"),
            forged(precious, rule: "no.such.rule")
        ], environment: env, rules: rules)
        XCTAssertEqual(report.failures.count, 5)
        XCTAssertTrue(report.deletedPaths.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: precious))
        XCTAssertTrue(fm.fileExists(atPath: sneaky))
        XCTAssertTrue(exists("home/Library/Caches"))
    }

    func testProtectedFoldersWinOverAnyRule() throws {
        try write("home/Documents/thesis.txt")
        try write("home/Library/Keychains/login.keychain-db")
        try write("home/Library/Mobile Documents/com~apple~CloudDocs/file.txt")
        let rogue = CleanupRule(id: "rogue", category: .appCaches, title: "", detail: "", targets: [
            .contents(env.homePath("Documents")), .contents(env.homePath("Library/Keychains")),
            .contents(env.homePath("Library/Mobile Documents")), .contents(env.home), .item(env.homePath("Library"))
        ])
        let result = CleanupEngine.scan(environment: env, rules: [rogue])
        let offered = Set(result.allItems.map(\.path))
        XCTAssertFalse(offered.contains { $0.contains("/Documents") || $0.contains("Keychains") || $0.contains("Mobile Documents") })
        XCTAssertFalse(offered.contains(env.homePath("Library")))
        let safety = CleanupSafety(environment: env)
        XCTAssertNotNil(safety.refusalReason(path: env.homePath("Documents/thesis.txt"), rule: rogue))
        XCTAssertNotNil(safety.refusalReason(path: env.homePath("Library"), rule: rogue))
        XCTAssertNotNil(safety.refusalReason(path: (env.home as NSString).deletingLastPathComponent, rule: rogue))
    }

    func testLocationRedirectedIntoProtectedFolderIsRefused() throws {
        try write("home/Documents/thesis.txt", bytes: 8_000)
        // ~/Library/Caches/evil is a symlink to ~/Documents: its "children" are the user's documents.
        try fm.createSymbolicLink(atPath: root + "/home/Library/Caches/evil", withDestinationPath: root + "/home/Documents")
        let rule = CleanupRule(id: "evil", category: .appCaches, title: "", detail: "",
                               targets: [.contents(env.homePath("Library/Caches/evil"))])
        XCTAssertTrue(CleanupEngine.scan(environment: env, rules: [rule]).allItems.isEmpty)
        XCTAssertNotNil(CleanupSafety(environment: env).refusalReason(path: env.homePath("Library/Caches/evil/thesis.txt"), rule: rule))
        // The generic rule sees the link itself: it takes no space, so it is not even offered.
        XCTAssertTrue(CleanupEngine.scan(environment: env, rules: [cachesRule]).allItems.isEmpty)
        XCTAssertTrue(exists("home/Documents/thesis.txt"))
    }

    func testRelocatedCacheFolderStillWorks() throws {
        // Developers often move DerivedData to another drive and leave a symlink behind.
        try write("sys/Volumes/Fast/DD/ProjectA/build.o", bytes: 8_000)
        try fm.createDirectory(atPath: root + "/home/Library/Developer/Xcode", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: root + "/home/Library/Developer/Xcode/DerivedData", withDestinationPath: root + "/sys/Volumes/Fast/DD")
        let rule = CleanupRule(id: "dd", category: .xcode, title: "", detail: "",
                               targets: [.contents(env.homePath("Library/Developer/Xcode/DerivedData"))])
        let items = CleanupEngine.scan(environment: env, rules: [rule]).allItems
        XCTAssertEqual(items.map(\.displayName), ["ProjectA"])
        XCTAssertTrue(CleanupEngine.delete(items: items, environment: env, rules: [rule]).failures.isEmpty)
        XCTAssertFalse(exists("sys/Volumes/Fast/DD/ProjectA"))
        XCTAssertTrue(exists("sys/Volumes/Fast/DD"))
    }

    // MARK: Catalog

    func testCatalogIsWellFormedAndNeverTargetsUserData() throws {
        let rules = CleanupCatalog.rules(for: env)
        XCTAssertEqual(Set(rules.map(\.id)).count, rules.count, "Rule ids are unique")
        let safety = CleanupSafety(environment: env)
        let allowedRoots = [env.home + "/", env.tempDirectory, env.systemRoot + "/"]
        for rule in rules {
            XCTAssertFalse(rule.title.isEmpty, rule.id)
            XCTAssertFalse(rule.detail.isEmpty, rule.id)
            XCTAssertFalse(rule.targets.isEmpty, rule.id)
            for target in rule.targets {
                let pattern: String
                switch target {
                case .contents(let p): pattern = p + "/x"
                case .item(let p): pattern = p
                }
                XCTAssertTrue(allowedRoots.contains { pattern.hasPrefix($0) }, "\(rule.id): \(pattern)")
                XCTAssertTrue(CleanupPath.isCanonicalForm(pattern), "\(rule.id): \(pattern)")
                // What the pattern points at must not be a protected place.
                let sample = pattern.replacingOccurrences(of: "*", with: "x")
                XCTAssertFalse(safety.isProtected(sample), "\(rule.id) targets a protected location: \(pattern)")
            }
        }
        // User data that no rule may ever claim.
        for precious in [
            "Documents/thesis.txt", "Desktop/photo.jpg", "Pictures/Photos Library.photoslibrary", "notes.txt",
            "Library/Keychains/login.keychain-db", "Library/Preferences/com.apple.finder.plist",
            "Library/Mobile Documents/com~apple~CloudDocs", "Library/Application Support/Google",
            "Library/Application Support/MobileSync", "Library/Mail/V10", "Library/Messages/chat.db",
            "Library/Safari/History.db", "Library/Containers/com.apple.mail", "Movies/holiday.mov",
            "Library/Application Support/Google/Chrome/Default/Cookies",
            "Library/Application Support/Google/Chrome/Default/History",
            "Library/Application Support/Slack/Local Storage", "Library/Application Support/Code/User",
            ".ssh/id_ed25519", ".zshrc", "Downloads/thesis.pdf", "Downloads/photo.jpg"
        ] {
            let path = env.homePath(precious)
            for rule in rules {
                XCTAssertNotNil(safety.refusalReason(path: path, rule: rule), "\(rule.id) would delete \(precious)")
            }
        }
    }

    func testCatalogScanOfAFakeHomeFindsTheUsualSuspects() throws {
        try write("home/.Trash/old.zip", bytes: 4_000)
        try write("home/Library/Caches/com.vendor.app/cache.db", bytes: 4_000)
        try write("home/Library/Caches/Google/Chrome/Default/Cache/data_1", bytes: 4_000)
        try write("home/Library/Logs/SomeApp/app.log", bytes: 4_000)
        try write("home/Library/Developer/Xcode/DerivedData/MyApp-abc/Build/x.o", bytes: 4_000)
        try write("home/.npm/_cacache/content-v2/aa/bb", bytes: 4_000)
        try write("home/Documents/thesis.txt", bytes: 4_000)
        let result = CleanupEngine.scan(environment: env)
        let found = Set(result.categories.map(\.category))
        XCTAssertTrue(found.isSuperset(of: [.trash, .appCaches, .browserCaches, .logs, .xcode, .devTools]), "\(found)")
        XCTAssertFalse(result.allItems.contains { $0.path.contains("/Documents/") })

        let ticked = result.allItems.filter(\.preselected)
        let report = CleanupEngine.delete(items: ticked, environment: env)
        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)")
        XCTAssertTrue(exists("home/Documents/thesis.txt"))
        XCTAssertFalse(exists("home/.Trash/old.zip"))
        XCTAssertFalse(exists("home/Library/Caches/com.vendor.app"))
    }
}
