import Foundation

// The list of places Cleanup looks at. Every entry is explained, with sources, in
// docs/CLEANUP.md; change the two together. Rules of thumb used here:
//   - `.safe` only for data the owning app regenerates or re-downloads by itself.
//   - `.caution` (never ticked by default) when deleting costs time, a big download,
//     or data that does not come back.
//   - Anything that needs root, or that the owning tool must remove itself
//     (simulators, Docker, snapshots), is not listed at all.

public enum CleanupCatalog {

    public static func trashRules(for env: CleanupEnvironment) -> [CleanupRule] {
        [
            CleanupRule(
                id: "trash.home", category: .trash, title: "Trash",
                detail: "Files you already moved to the Trash. Deleting them is what Empty Trash does; they cannot be put back afterwards.",
                targets: [.contents(env.homePath(".Trash"))], listEmptyItems: true
            ),
            CleanupRule(
                id: "trash.volumes", category: .trash, title: "Trash on other drives",
                detail: "Your Trash folder on each mounted drive (.Trashes). Space is freed on that drive.",
                targets: [.contents(env.systemPath("/Volumes") + "/*/.Trashes/\(env.userID)")], listEmptyItems: true
            )
        ]
    }

    public static func rules(for env: CleanupEnvironment) -> [CleanupRule] {
        trashRules(for: env) + browserRules(env) + xcodeRules(env) + devToolRules(env)
            + appDataRules(env) + logRules(env) + tempRules(env) + largeLeftoverRules(env) + cacheRules(env)
    }

    // MARK: Browsers

    /// Cache-only folders inside a Chromium profile folder. Cookies, History, Login Data,
    /// Local Storage, IndexedDB, Extensions and Service Worker/ScriptCache are never touched.
    private static func chromiumLeaves(_ base: String) -> [CleanupTarget] {
        var targets: [CleanupTarget] = []
        for leaf in ["Code Cache", "GPUCache", "DawnCache", "GrShaderCache", "GraphiteDawnCache", "Application Cache"] {
            targets.append(.item(base + "/*/" + leaf))
        }
        for leaf in ["ShaderCache", "GrShaderCache", "GraphiteDawnCache"] {
            targets.append(.item(base + "/" + leaf))
        }
        return targets
    }

    private static func browserRules(_ env: CleanupEnvironment) -> [CleanupRule] {
        let caches = env.homePath("Library/Caches")
        let support = env.homePath("Library/Application Support")
        let detail = "Cached pages, images and compiled scripts. Sites load from the network again. Cookies, history, passwords and extensions are not touched. Quit the browser first."
        func browser(_ id: String, _ title: String, _ bundleIDs: [String], _ targets: [CleanupTarget]) -> CleanupRule {
            CleanupRule(id: "browser." + id, category: .browserCaches, title: title, detail: detail,
                        targets: targets, bundleIDs: bundleIDs, keepRoot: true)
        }
        return [
            browser("safari", "Safari", ["com.apple.Safari"], [
                .item(caches + "/com.apple.Safari"), .item(caches + "/com.apple.WebKit.Networking"),
                .item(env.homePath("Library/Containers/com.apple.Safari/Data/Library/Caches"))
            ]),
            browser("chrome", "Google Chrome", ["com.google.Chrome"],
                    [.item(caches + "/Google/Chrome")] + chromiumLeaves(support + "/Google/Chrome")),
            browser("chromium", "Chromium", ["org.chromium.Chromium"],
                    [.item(caches + "/Chromium")] + chromiumLeaves(support + "/Chromium")),
            browser("edge", "Microsoft Edge", ["com.microsoft.edgemac"],
                    [.item(caches + "/com.microsoft.edgemac"), .item(caches + "/Microsoft Edge")]
                        + chromiumLeaves(support + "/Microsoft Edge")),
            browser("brave", "Brave", ["com.brave.Browser"],
                    [.item(caches + "/BraveSoftware/Brave-Browser")] + chromiumLeaves(support + "/BraveSoftware/Brave-Browser")),
            browser("arc", "Arc", ["company.thebrowser.Browser"],
                    [.item(caches + "/company.thebrowser.Browser"), .item(caches + "/Arc")]
                        + chromiumLeaves(support + "/Arc/User Data")),
            browser("firefox", "Firefox", ["org.mozilla.firefox"], [
                .item(caches + "/Firefox/Profiles/*/cache2"), .item(caches + "/Firefox/Profiles/*/startupCache"),
                .item(support + "/Firefox/Profiles/*/cache2")
            ]),
            browser("vivaldi", "Vivaldi", ["com.vivaldi.Vivaldi"], [.item(caches + "/com.vivaldi.Vivaldi"), .item(caches + "/Vivaldi")]),
            browser("opera", "Opera", ["com.operasoftware.Opera"], [.item(caches + "/com.operasoftware.Opera")]),
            browser("orion", "Orion", ["com.kagi.kagimacOS"], [.item(caches + "/com.kagi.kagimacOS")])
        ]
    }

    // MARK: Xcode

    private static func xcodeRules(_ env: CleanupEnvironment) -> [CleanupRule] {
        let dev = env.homePath("Library/Developer")
        let caches = env.homePath("Library/Caches")
        let xcode = ["com.apple.dt.Xcode"]
        let simulator = ["com.apple.dt.Xcode", "com.apple.iphonesimulator"]
        return [
            CleanupRule(id: "xcode.deriveddata", category: .xcode, title: "DerivedData (build products & indexes)",
                        detail: "Build output, indexes and module caches per project. Safe to delete; the next build and indexing of each project take longer. Quit Xcode first.",
                        targets: [.contents(dev + "/Xcode/DerivedData")], bundleIDs: xcode),
            CleanupRule(id: "xcode.caches", category: .xcode, title: "Xcode caches",
                        detail: "Xcode's own caches and the documentation cache. Rebuilt on demand.",
                        targets: [.item(caches + "/com.apple.dt.Xcode"), .item(caches + "/com.apple.dt.xcodebuild"),
                                  .item(dev + "/Xcode/DocumentationCache"), .item(dev + "/Xcode/DocumentationIndex")],
                        bundleIDs: xcode, keepRoot: true),
            CleanupRule(id: "xcode.simcaches", category: .xcode, title: "Simulator caches",
                        detail: "Shared caches of the simulators and leftover test-clone devices. Rebuilt at the next simulator boot, which is then slower. Simulator devices and runtimes are not touched (remove those in Xcode or with xcrun simctl).",
                        targets: [.contents(dev + "/CoreSimulator/Caches"), .contents(dev + "/XCTestDevices")], bundleIDs: simulator),
            CleanupRule(id: "xcode.devicelogs", category: .xcode, title: "Device logs",
                        detail: "Logs copied from connected devices.",
                        targets: [.contents(dev + "/Xcode/iOS Device Logs")], bundleIDs: xcode),
            CleanupRule(id: "xcode.devicesupport", category: .xcode, title: "Device support files",
                        detail: "Debug symbols for each OS version of the devices you connected (1–3 GB each). Copied from the device again when it connects, which takes a few minutes. Keep the versions you still debug on.",
                        risk: .caution,
                        targets: ["iOS", "watchOS", "tvOS", "visionOS", "xrOS", "macOS"].map { .contents(dev + "/Xcode/\($0) DeviceSupport") },
                        bundleIDs: xcode),
            CleanupRule(id: "xcode.archives", category: .xcode, title: "Archives",
                        detail: "Archived builds with their debug symbols. NOT regenerated: you need the archive of a shipped build to symbolicate its crash reports or export it again.",
                        risk: .caution, targets: [.contents(dev + "/Xcode/Archives")], bundleIDs: xcode),
            CleanupRule(id: "xcode.packages", category: .xcode, title: "Swift Package Manager, CocoaPods & Carthage caches",
                        detail: "Downloaded package repositories and pods. Fetched again at the next resolve or pod install.",
                        targets: [.item(caches + "/org.swift.swiftpm"), .item(env.homePath(".cache/swift-package-manager")),
                                  .item(caches + "/CocoaPods"), .item(caches + "/org.carthage.CarthageKit")],
                        keepRoot: true)
        ]
    }

    // MARK: Developer tools

    private static func devToolRules(_ env: CleanupEnvironment) -> [CleanupRule] {
        let caches = env.homePath("Library/Caches")
        let support = env.homePath("Library/Application Support")
        func h(_ relative: String) -> String { env.homePath(relative) }
        let redownload = "Downloaded packages kept for reuse. Downloaded again when a project needs them."
        return [
            CleanupRule(id: "dev.homebrew", category: .devTools, title: "Homebrew downloads",
                        detail: "Downloaded bottles and installers (what brew cleanup removes). Installed software is not touched.",
                        targets: [.item(caches + "/Homebrew")], keepRoot: true),
            CleanupRule(id: "dev.node", category: .devTools, title: "npm, Yarn, Bun & node-gyp caches",
                        detail: redownload + " node_modules folders of your projects are not touched.",
                        targets: [.item(h(".npm/_cacache")), .item(h(".npm/_logs")), .item(caches + "/Yarn"),
                                  .item(h(".bun/install/cache")), .item(h(".cache/node-gyp")), .item(caches + "/node-gyp"),
                                  .item(h(".cache/electron")), .item(caches + "/electron"), .item(h(".cache/typescript")),
                                  .item(caches + "/typescript")],
                        keepRoot: true),
            CleanupRule(id: "dev.python", category: .devTools, title: "pip, Poetry & Python tool caches",
                        detail: redownload + " Virtual environments are not touched.",
                        targets: [.item(caches + "/pip"), .item(caches + "/pypoetry/artifacts"), .item(caches + "/pypoetry/cache"),
                                  .item(h(".pyenv/cache")), .item(h(".cache/ruff")), .item(h(".cache/mypy")), .item(h(".cache/pre-commit"))],
                        keepRoot: true),
            CleanupRule(id: "dev.uv", category: .devTools, title: "uv cache",
                        detail: "uv's package cache. uv prefers that you run \"uv cache prune\" yourself; deleting it here is the same as \"uv cache clean\" and everything is downloaded again.",
                        risk: .caution, targets: [.item(h(".cache/uv"))], keepRoot: true),
            CleanupRule(id: "dev.go", category: .devTools, title: "Go build cache",
                        detail: "Compiled packages (go clean -cache). The next build recompiles everything.",
                        targets: [.item(caches + "/go-build")], keepRoot: true),
            CleanupRule(id: "dev.gomod", category: .devTools, title: "Go module cache",
                        detail: "Downloaded module sources (go clean -modcache). All modules are downloaded again; needs network.",
                        risk: .caution, targets: [.contents(h("go/pkg/mod"))]),
            CleanupRule(id: "dev.rust", category: .devTools, title: "Cargo registry cache",
                        detail: "Downloaded crates and their unpacked sources. Cargo restores them on the next build. Installed binaries, credentials and toolchains are not touched.",
                        targets: [.item(h(".cargo/registry/cache")), .item(h(".cargo/registry/src"))], keepRoot: true),
            CleanupRule(id: "dev.ruby-php", category: .devTools, title: "Ruby gems & Composer caches",
                        detail: redownload + " Installed gems are not touched.",
                        targets: [.item(h(".gem/ruby/*/cache")), .item(h(".bundle/cache")), .item(h(".rbenv/cache")),
                                  .item(caches + "/composer"), .item(h(".composer/cache"))],
                        keepRoot: true),
            CleanupRule(id: "dev.gradle", category: .devTools, title: "Gradle caches",
                        detail: "Dependencies and build caches. Gradle trims these itself; deleting them means a long re-download on the next build. Stop the Gradle daemon first.",
                        risk: .caution, targets: [.contents(h(".gradle/caches"))]),
            CleanupRule(id: "dev.android", category: .devTools, title: "Android build caches",
                        detail: "Android SDK download and build caches. The SDK and emulator images are not touched.",
                        targets: [.item(h(".android/cache")), .item(h(".android/build-cache"))], keepRoot: true),
            CleanupRule(id: "dev.jetbrains", category: .devTools, title: "JetBrains IDE caches",
                        detail: "Indexes of IntelliJ, PyCharm, Android Studio and others. Re-indexing a large project can take a long time. Settings and plugins are not touched.",
                        risk: .caution, targets: [.contents(caches + "/JetBrains"), .item(caches + "/Google/AndroidStudio*")]),
            CleanupRule(id: "dev.vscode", category: .devTools, title: "Visual Studio Code caches",
                        detail: "Web caches, cached extension downloads and logs. Settings, extensions and workspace state are not touched. Quit VS Code first.",
                        targets: ["Cache", "CachedData", "CachedExtensionVSIXs", "Code Cache", "GPUCache", "logs"]
                            .map { .item(support + "/Code/" + $0) },
                        bundleIDs: ["com.microsoft.VSCode"], keepRoot: true)
        ]
    }

    // MARK: Chat, media, editors

    private static func appDataRules(_ env: CleanupEnvironment) -> [CleanupRule] {
        let caches = env.homePath("Library/Caches")
        let support = env.homePath("Library/Application Support")
        func electron(_ id: String, _ title: String, _ folder: String, _ bundleIDs: [String]) -> CleanupRule {
            CleanupRule(id: "app." + id, category: .appData, title: title,
                        detail: "Web cache of the app. Messages, logins and settings are not touched. Quit the app first.",
                        targets: ["Cache", "Code Cache", "GPUCache"].map { .item(support + "/" + folder + "/" + $0) },
                        bundleIDs: bundleIDs, keepRoot: true)
        }
        return [
            electron("slack", "Slack cache", "Slack", ["com.tinyspeck.slackmacgap"]),
            electron("discord", "Discord cache", "discord", ["com.hnc.Discord"]),
            electron("teams-classic", "Microsoft Teams (classic) cache", "Microsoft/Teams", ["com.microsoft.teams"]),
            CleanupRule(id: "app.steam", category: .appData, title: "Steam caches",
                        detail: "Steam's web, depot and shader caches and logs. Games and saves are not touched.",
                        targets: ["appcache", "depotcache", "htmlcache", "logs"].map { .item(support + "/Steam/" + $0) },
                        bundleIDs: ["com.valvesoftware.steam"], keepRoot: true),
            CleanupRule(id: "app.spotify", category: .appData, title: "Spotify cache",
                        detail: "Streaming cache. It can also hold music you downloaded for offline listening, which would have to be downloaded again.",
                        risk: .caution,
                        targets: [.item(caches + "/com.spotify.client"), .item(support + "/Spotify/PersistentCache")],
                        bundleIDs: ["com.spotify.client"], keepRoot: true),
            CleanupRule(id: "app.resolve", category: .appData, title: "DaVinci Resolve render cache",
                        detail: "Render cache clips (CacheClip). Resolve renders them again when you open the timeline, which takes time. Projects and media are not touched. Quit Resolve first.",
                        risk: .caution, targets: [.contents(env.homePath("Movies/CacheClip"))],
                        bundleIDs: ["com.blackmagic-design.DaVinciResolve", "com.blackmagic-design.DaVinciResolveLite"]),
            CleanupRule(id: "app.adobe", category: .appData, title: "Adobe media cache",
                        detail: "Conformed audio and preview files of Premiere Pro, After Effects and Media Encoder. Rebuilt when you open the project, which takes time. Quit the Adobe apps first.",
                        risk: .caution,
                        targets: [.contents(support + "/Adobe/Common/Media Cache Files"), .contents(support + "/Adobe/Common/Media Cache")]),
            CleanupRule(id: "app.maildownloads", category: .appData, title: "Mail attachment copies",
                        detail: "Copies of attachments you opened in Mail, untouched for 30 days. The originals stay in the messages. If you edited one of these copies, the edit exists only here.",
                        risk: .caution,
                        targets: [.contents(env.homePath("Library/Containers/com.apple.mail/Data/Library/Mail Downloads"))],
                        minAgeDays: 30, bundleIDs: ["com.apple.mail"])
        ]
    }

    // MARK: Logs

    private static func logRules(_ env: CleanupEnvironment) -> [CleanupRule] {
        [
            CleanupRule(id: "logs.user", category: .logs, title: "Application logs",
                        detail: "Log files apps wrote for troubleshooting. Only the history is lost; apps keep logging.",
                        targets: [.contents(env.homePath("Library/Logs"))],
                        excludedNames: ["CZ.commander"]),
            CleanupRule(id: "logs.crash", category: .logs, title: "Crash & diagnostic reports",
                        detail: "Reports macOS wrote when an app crashed or hung. Only useful if you still want to send one to a developer.",
                        targets: [.contents(env.homePath("Library/Logs/DiagnosticReports")),
                                  .contents(env.homePath("Library/Application Support/CrashReporter"))])
        ]
    }

    // MARK: Temporary files

    private static func tempRules(_ env: CleanupEnvironment) -> [CleanupRule] {
        [
            CleanupRule(id: "temp.user", category: .tempFiles, title: "Temporary files (older than 7 days)",
                        detail: "Your temporary folder ($TMPDIR). Only items in which nothing changed for 7 days are listed, and folders in use by a running app are skipped. macOS empties most of this at restart anyway.",
                        risk: .caution, targets: [.contents(env.tempDirectory)], minAgeDays: 7,
                        excludedNames: ["TemporaryItems"], excludedPrefixes: ["com.apple.", "."]),
            CleanupRule(id: "temp.downloads", category: .tempFiles, title: "Unfinished downloads (older than 7 days)",
                        detail: "Partial files browsers left in Downloads (.download, .crdownload, .part). An interrupted download cannot be resumed after this.",
                        risk: .caution, targets: [.contents(env.homePath("Downloads"))], minAgeDays: 7,
                        allowedExtensions: ["download", "crdownload", "part"])
        ]
    }

    // MARK: Large leftovers

    private static func largeLeftoverRules(_ env: CleanupEnvironment) -> [CleanupRule] {
        let updates = ["iPhone", "iPad", "iPod", "Apple TV"].map {
            CleanupTarget.contents(env.homePath("Library/iTunes/\($0) Software Updates"))
        }
        return [
            CleanupRule(id: "large.iosbackups", category: .largeLeftovers, title: "iPhone & iPad backups",
                        detail: "Local device backups made in Finder. NOT regenerated: a deleted backup cannot be recovered. Delete only backups of devices you no longer need to restore.",
                        risk: .caution, targets: [.contents(env.homePath("Library/Application Support/MobileSync/Backup"))]),
            CleanupRule(id: "large.firmware", category: .largeLeftovers, title: "iPhone & iPad software updates",
                        detail: "Downloaded firmware files (.ipsw). Apple offers them for download again when needed.",
                        risk: .caution, targets: updates),
            CleanupRule(id: "large.installers", category: .largeLeftovers, title: "Disk images & installers in Downloads",
                        detail: "Downloaded .dmg, .pkg and .iso files. Usually no longer needed once the app is installed, but these are your files: check the list.",
                        risk: .caution, targets: [.contents(env.homePath("Downloads"))],
                        allowedExtensions: ["dmg", "pkg", "iso", "xip"])
        ]
    }

    // MARK: Generic caches (last: the rules above claim their own folders first)

    private static func cacheRules(_ env: CleanupEnvironment) -> [CleanupRule] {
        let caches = env.homePath("Library/Caches")
        return [
            CleanupRule(id: "caches.apple", category: .appCaches, title: "Apple app caches",
                        detail: "Caches of Mail, Maps, Help, the App Store and media services that are known to be rebuilt. Other com.apple caches (fonts, Spotlight, iCloud, Dock, Settings, audio) are never listed: deleting those breaks things.",
                        targets: ["com.apple.mail", "com.apple.helpd", "GeoServices", "com.apple.AppleMediaServices",
                                  "com.apple.parsecd", "com.apple.python", "com.apple.appstore", "com.apple.FinalCut",
                                  "com.apple.Music", "com.apple.podcasts", "com.apple.TV"].map { .item(caches + "/" + $0) },
                        keepRoot: true),
            CleanupRule(id: "caches.user", category: .appCaches, title: "Application caches",
                        detail: "One cache folder per app in ~/Library/Caches. Apps rebuild or re-download what they need, so the first launch afterwards can be slower. Quit an app before deleting its cache.",
                        targets: [.contents(caches)],
                        excludedNames: [
                            // Sync or account state with a cache-like name
                            "CloudKit", "FamilyCircle", "GIPPseudonymousID", "CCTClearcutLogger",
                            "com.getdropbox.dropbox", "com.google.GoogleDrive", "com.microsoft.OneDrive", "com.microsoft.OneDriveStandaloneUpdater",
                            // Not rebuilt automatically: model weights, test browsers, package stores, runtimes
                            "llama.cpp", "Buzz", "kitty", "deno", "pnpm", "Cypress", "camoufox", "huggingface", "puppeteer",
                            // CZ.commander itself
                            "com.czcommander.macos", "CZ.commander"
                        ],
                        excludedPrefixes: ["com.apple.", "Adobe", "ms-playwright", "com.jetbrains.toolbox", "."],
                        excludedSubstrings: ["coreaudio", "controlcenter", "systemsettings", "systempreferences",
                                             "shortcutssandboxcache", "e5rt", "crowdstrike", "sentinel", "1password", "ilok"]),
            CleanupRule(id: "caches.containers", category: .appCaches, title: "Sandboxed app caches",
                        detail: "The Caches folder inside each sandboxed app's container. Only the cache is emptied; the app's documents and settings in the container are not touched. Needs Full Disk Access.",
                        targets: [.item(env.homePath("Library/Containers/*/Data/Library/Caches"))],
                        excludedPrefixes: ["com.apple.", "com.docker.", "dev.orbstack"],
                        excludedSubstrings: ["1password", "bitwarden", "keepass"],
                        keepRoot: true)
        ]
    }
}
