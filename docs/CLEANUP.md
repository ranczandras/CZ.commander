# Cleanup: what is scanned, what is deleted, and why

Reference for the Cleanup module (`Sources/CZCommanderCore/Tools/CleanupEngine.swift`, `CleanupCatalog.swift`, `Sources/CZCommanderApp/Views/CleanupSheets.swift`). The catalog and this document must change together.

Cleanup frees disk space by deleting data that is already thrown away (Trash) or that its owner can rebuild (caches, logs, build products). It does not make the Mac faster: caches exist to speed things up, and macOS already purges registered caches by itself when space runs low. After a cleanup the first launch of an app, the first build or the first page load is slower.

## How it works

1. **Scan** (read-only). Every catalog rule is expanded to the folders that exist; each folder or file found becomes one item with its size on disk (allocated blocks, hard links counted once) and the date of the newest file inside.
2. **Pick.** Items are grouped as category → group (one rule) → item, each level with a checkbox. `safe` groups are ticked by default, `caution` groups ("review first") never are, and items of an app that is running are never ticked by default.
3. **Confirm and delete.** Nothing is deleted before the confirmation bar is answered. Deletion is permanent by default; "Move to Trash instead of deleting" makes it undoable but frees no space until the Trash is emptied.
4. **Report.** Freed bytes and every item that could not be removed completely, then an automatic rescan.

The **Empty Trash** button deletes the contents of `~/.Trash` and of `/Volumes/*/.Trashes/<uid>` directly. Without Full Disk Access macOS hides `~/.Trash`; the dialog then offers Full Disk Access or "Empty with Finder" (an Apple Event to Finder; macOS asks once for permission to control Finder, and Finder shows its own warning if that is enabled in its settings).

## Safety rules in the engine

Every deletion passes all of these, checked again immediately before the item is removed (`CleanupSafety.refusalReason`):

| Rule | Why |
|---|---|
| **Allowlist.** A path is deleted only if it matches a catalog pattern exactly (same depth, exclusions and extension filters included). | A bug in the UI or a forged item cannot reach arbitrary files. |
| **Denylist on top.** Protected folders (below) are refused even if a rule matches. Compared case-insensitively, like APFS. | A wrong rule cannot delete user data. |
| **Clean paths only.** Absolute, normalized, no `.` or `..`, at least three components deep. | No climbing out of a cache folder. |
| **Symlinks are never followed.** A link is removed as a link (Trash) or ignored (everywhere else). If a location resolves into a protected folder it is refused. A relocated cache folder (DerivedData symlinked to another drive) still works. | Mole and others had real incidents with symlinked cache roots. |
| **No crossing onto another volume** while measuring or deleting (`FTS_XDEV`). | A mounted disk image inside a cache folder is not emptied. |
| **Delete the contents, keep the folder** for app-owned cache roots (`keepRoot`). | Some apps and daemons do not recreate their cache folder, or keep it open. |
| **Skip anything holding a socket, pipe or device node.** | That folder is in use by a running process right now. |
| **Age limit** where "old" is the only safe signal (temporary files 7 days, Mail attachment copies 30 days). The newest file anywhere inside decides. | Fresh temporary files belong to running apps. |
| **Running apps:** their items are listed with a badge but not ticked, and the confirmation warns. | Deleting a cache under a running app can break it until restart (open SQLite caches, Chrome's HTTP cache, compiled ML models). |
| **Errors do not stop the run.** Locked (`uchg`) files are unlocked, read-only folders (Go module cache) are made writable; what still fails is reported per item. | `Operation not permitted` means macOS protection (TCC/SIP), `Permission denied` means file permissions. |
| **No root, no `sudo`.** Locations that need it are not listed. | No checkbox that is bound to fail. |

Not implemented (possible follow-ups): checking open file handles per file (`lsof`), calling the owner's own cleaner (`brew cleanup`, `xcrun simctl delete unavailable`, `docker system prune`), and comparing device/inode between scan and delete.

## Categories

Legend: **safe** = ticked by default, **caution** = "review first", never ticked by default.

### Trash
| Location | Risk | Notes |
|---|---|---|
| `~/.Trash/*` | safe | Needs Full Disk Access to read. Includes `.DS_Store`, which holds the Put Back information. |
| `/Volumes/*/.Trashes/<uid>/*` | safe | Only your own user's folder on each drive. |

Not touched: the iCloud Drive trash (`~/Library/Mobile Documents/.Trash`). iCloud expires it after 30 days and deletions there sync to the cloud. Space freed from the Trash may not show up as free space while an APFS snapshot (Time Machine) still references the blocks.

### Application caches
| Location | Risk | Notes |
|---|---|---|
| `~/Library/Caches/<app>` (each folder is one item) | safe | Apple's contract: "cached data that can be regenerated as needed". |
| `~/Library/Containers/<app>/Data/Library/Caches` (emptied, folder kept) | safe | Needs Full Disk Access. Everything else in a container is app data and is never touched. |
| A fixed list of Apple caches: Mail, Help, GeoServices (Maps), AppleMediaServices, parsecd, python, App Store, Final Cut, Music, Podcasts, TV | safe | Known to be rebuilt. |

Never listed from `~/Library/Caches`, because deleting them breaks something instead of costing a rebuild:

- every other `com.apple.*` folder (FontRegistry: font rendering; Spotlight: search; Finder, Dock, Control Center, System Settings: blank panels; `containermanagerd`, `homed`, HomeKit, `FamilyCircle`: service state; audio caches: lost audio output on some Macs)
- `CloudKit`, Dropbox, Google Drive and OneDrive caches (sync state)
- `GIPPseudonymousID`, `CCTClearcutLogger` (deleting them under a running Google app starts an endless write loop)
- `Adobe*` (licence and plug-in state), anything named like iLok, 1Password, CrowdStrike, SentinelOne
- `ms-playwright*`, `Cypress`, `camoufox`, `puppeteer` (downloaded test browsers), `llama.cpp`, `huggingface`, `Buzz` (model weights), `pnpm`, `deno`, `kitty`
- CZ.commander's own cache
- Apple and Docker/OrbStack containers, password-manager containers

### Browser caches
Safari, Chrome, Chromium, Edge, Brave, Arc, Firefox, Vivaldi, Opera, Orion. All **safe**, folders emptied and kept, flagged when the browser is running.

- The browser's folder in `~/Library/Caches` (Safari also `com.apple.WebKit.Networking` and its container cache; Firefox only `Profiles/*/cache2` and `startupCache`).
- Chromium-based: inside each profile only `Code Cache`, `GPUCache`, `DawnCache`, `GrShaderCache`, `GraphiteDawnCache`, `Application Cache`, plus the top-level shader caches.

Never touched: `Cookies`, `History`, `Login Data`, `Web Data`, `Bookmarks`, `Preferences`, `Local Storage`, `IndexedDB`, `Extensions`, and `Service Worker` (deleting `ScriptCache` breaks extensions even with the browser closed).

### Logs & crash reports
| Location | Risk |
|---|---|
| `~/Library/Logs/*` | safe |
| `~/Library/Logs/DiagnosticReports/*`, `~/Library/Application Support/CrashReporter/*` | safe |

Only troubleshooting history is lost. `/Library/Logs`, `/private/var/log` and the unified log store need root and are not listed.

### Temporary files
| Location | Risk | Notes |
|---|---|---|
| `$TMPDIR/*` (`/private/var/folders/…/T`), older than 7 days | caution | `com.apple.*`, hidden entries and `TemporaryItems` are skipped. macOS clears most of this at restart. |
| `~/Downloads/*.download`, `*.crdownload`, `*.part`, older than 7 days | caution | Unfinished browser downloads. |

Not listed: `/private/tmp` and `/private/var/tmp` (shared, age does not prove the files are disposable) and the per-user cache folder `/private/var/folders/…/C` (holds licence state of some audio/video software and system caches).

### Xcode & simulators
| Location | Risk | Cost of deleting |
|---|---|---|
| `~/Library/Developer/Xcode/DerivedData/*` | safe | Next build and indexing are slow. |
| `~/Library/Caches/com.apple.dt.Xcode`, `com.apple.dt.xcodebuild`, `Xcode/DocumentationCache`, `DocumentationIndex` | safe | Rebuilt. |
| `~/Library/Developer/CoreSimulator/Caches/*`, `~/Library/Developer/XCTestDevices/*` | safe | Next simulator boot is slow. |
| `~/Library/Developer/Xcode/iOS Device Logs/*` | safe | – |
| SwiftPM (`~/Library/Caches/org.swift.swiftpm`, `~/.cache/swift-package-manager`), CocoaPods, Carthage caches | safe | Packages are fetched again. |
| `~/Library/Developer/Xcode/{iOS,watchOS,tvOS,visionOS,xrOS,macOS} DeviceSupport/*` | caution | 1–3 GB per OS version; copied from the device again when it connects. |
| `~/Library/Developer/Xcode/Archives/*` | caution | **Not regenerated.** Needed to symbolicate crashes of shipped builds. |

Not listed: simulator devices and runtimes (`CoreSimulator/Devices`, `/Library/Developer/CoreSimulator/Volumes`). Apple: do not manage them by hand; use Xcode or `xcrun simctl delete unavailable` / `xcrun simctl runtime delete`. `Xcode/UserData` (snippets, key bindings, breakpoints) is user data.

### Developer tool caches
| Tool | Location | Risk |
|---|---|---|
| Homebrew | `~/Library/Caches/Homebrew` | safe |
| npm, Yarn classic, Bun, node-gyp, Electron, TypeScript | `~/.npm/_cacache`, `~/.npm/_logs`, `~/Library/Caches/Yarn`, `~/.bun/install/cache`, `~/.cache/…` | safe |
| pip, Poetry (only `artifacts` and `cache`), pyenv, ruff, mypy, pre-commit | `~/Library/Caches/pip`, `~/Library/Caches/pypoetry/{artifacts,cache}`, … | safe |
| Go build cache | `~/Library/Caches/go-build` | safe |
| Cargo | `~/.cargo/registry/{cache,src}` | safe |
| Ruby gems, Bundler, rbenv, Composer | `~/.gem/ruby/*/cache`, `~/.bundle/cache`, … | safe |
| Android | `~/.android/{cache,build-cache}` | safe |
| VS Code | `~/Library/Application Support/Code/{Cache,CachedData,CachedExtensionVSIXs,Code Cache,GPUCache,logs}` | safe |
| uv | `~/.cache/uv` | caution (uv asks you to use `uv cache prune`) |
| Go modules | `~/go/pkg/mod/*` | caution (full re-download) |
| Gradle | `~/.gradle/caches/*` | caution (long re-download; Gradle trims it itself) |
| JetBrains IDEs, Android Studio | `~/Library/Caches/JetBrains/*`, `~/Library/Caches/Google/AndroidStudio*` | caution (re-indexing can take very long) |

Not listed on purpose: `~/.m2/repository` (locally installed artifacts are lost), the pnpm store and Yarn Berry cache (projects link into them), conda `pkgs` (environments link into it), Poetry virtualenvs, `~/.npm/_npx`, Docker's `Docker.raw` (it *is* all images and volumes; use `docker system prune`), `~/.orbstack`, Ollama models, VS Code `User/` (settings, workspace state, unsaved editors) and `~/.vscode/extensions`.

### App leftovers
| Location | Risk | Notes |
|---|---|---|
| Slack, Discord, Teams classic: `Cache`, `Code Cache`, `GPUCache` in their Application Support folder | safe | Not `IndexedDB` / `Local Storage` (that resets the app). |
| Steam: `appcache`, `depotcache`, `htmlcache`, `logs` | safe | Never `steamapps/common` (games) or `userdata` (saves). |
| Spotify cache | caution | Can hold music downloaded for offline use. |
| DaVinci Resolve `~/Movies/CacheClip/*` | caution | Render cache; re-rendered on demand. |
| Adobe `Media Cache Files`, `Media Cache` | caution | Re-conformed when the project opens. |
| Mail attachment copies (`~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/*`), older than 30 days | caution | An edited copy may be the only version of that edit. |

Teams (new), Zoom, Telegram, WhatsApp and similar keep their cache in `~/Library/Caches` and appear under Application caches.

### Large leftovers (review first)
| Location | Risk | Notes |
|---|---|---|
| `~/Library/Application Support/MobileSync/Backup/*` | caution | iPhone/iPad backups. Apple: a deleted backup cannot be recovered. |
| `~/Library/iTunes/{iPhone,iPad,iPod,Apple TV} Software Updates/*` | caution | `.ipsw` firmware, downloadable again. |
| `~/Downloads/*.{dmg,pkg,iso,xip}` | caution | Your files; check the list. |

## Never deleted (protected in `CleanupSafety`)

- `/System`, `/usr`, `/bin`, `/sbin`, `/etc`, `/private/var/db` (TCC database, receipts), `/private/var/vm` (swap, sleep image), `/Library/Keychains`, `/Library/Preferences`, `/Library/Application Support`
- `~/Documents`, `~/Desktop`, `~/Pictures` and everything in them
- `~/Library/Mobile Documents` (iCloud Drive), `~/Library/CloudStorage`, `~/Library/Keychains`, `~/Library/Preferences`, `~/Library/Mail`, `~/Library/Messages`, `~/Library/Safari`, `~/Library/Cookies`, `~/Library/Calendars`, `~/Library/Accounts`, `~/Library/Photos`, `~/Library/Group Containers`
- `~/.ssh`, `~/.gnupg`, `~/.config`, `~/.aws`, `~/.kube`
- The folders themselves (their listed contents may go): the home folder and all its ancestors, `~/Library`, `~/Library/Caches`, `~/Library/Logs`, `~/Library/Application Support`, `~/Library/Containers`, `~/Downloads`, `~/Movies`, `~/Music`, `~/.Trash`, `/Applications`, `/Volumes`, `/private/tmp`

Deliberately out of scope, because the "fix" has caused real damage in other cleaners: rebuilding font caches or the LaunchServices database, deleting the Spotlight index, `.DS_Store` sweeps, Dock databases, `~/Library/Autosave Information`, Calendar caches, wallpaper/aerial assets, `/Library/Updates` (staged macOS updates), Time Machine local snapshots (use `tmutil`), macOS installers in `/Applications` (owned by root; drag them to the Trash in Finder).

## Sources

- Apple, File System Programming Guide: [File System Basics](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemOverview/FileSystemOverview.html), [macOS Library Directory Details](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/MacOSXDirectories/MacOSXDirectories.html)
- Apple Developer Forums (DTS): [On File System Permissions](https://developer.apple.com/forums/thread/678819), [Trash and TCC](https://developer.apple.com/forums/thread/745692), [Xcode folders that are safe to delete](https://developer.apple.com/forums/thread/812408)
- Apple Support: [device backups](https://support.apple.com/en-us/108809), [free up storage](https://support.apple.com/en-us/102624)
- Howard Oakley, The Eclectic Light Company: [how the Trash works](https://eclecticlight.co/2026/11/10/dumpster-diving-how-the-trash-works/), [caches and purging](https://eclecticlight.co/2026/09/02/caches-and-purging-in-macos-tahoe/), [snapshots](https://eclecticlight.co/2026/09/09/take-control-of-snapshots/), [protected folders](https://eclecticlight.co/2026/04/15/privacy-which-folders-are-protected-in-tahoe/)
- [tw93/Mole](https://github.com/tw93/Mole) source (`lib/clean/*.sh`, `lib/core/app_protection.sh`, `SECURITY_AUDIT.md`): the main model for the protection list and the incident history behind it. [Pearcleaner](https://github.com/alienator88/Pearcleaner) for developer paths. `mac-cleanup-py` / `mac-cleanup-sh` were read as counter-examples (they delete iOS backups, Xcode archives, browser cookies and app databases).
- Tool documentation: [Homebrew](https://docs.brew.sh/Manpage), [npm cache](https://docs.npmjs.com/cli/v11/commands/npm-cache), [pip caching](https://pip.pypa.io/en/stable/topics/caching/), [uv cache](https://docs.astral.sh/uv/concepts/cache/), [Cargo home](https://doc.rust-lang.org/cargo/guide/cargo-home.html), [Gradle directories](https://docs.gradle.org/current/userguide/directory_layout.html), [pnpm store](https://pnpm.io/cli/store), [conda clean](https://docs.conda.io/projects/conda/en/latest/commands/clean.html), [Bun cache](https://bun.sh/docs/install/cache), [Docker Desktop for Mac FAQ](https://docs.docker.com/desktop/troubleshoot-and-support/faqs/macfaqs/), [Chromium user data directory](https://chromium.googlesource.com/chromium/src/+/main/docs/user_data_dir.md), [VS Code uninstall](https://code.visualstudio.com/docs/setup/uninstall)

## Not yet verified on a real Mac

These paths come from one cleaner's source or from general knowledge, not from a primary document; a wrong path only means nothing is found there:

- Edge (`~/Library/Caches/Microsoft Edge` vs `com.microsoft.edgemac`), Spotify, sandboxed Slack, Safari's container cache
- Adobe `Media Cache` (database folder), Carthage cache, `~/Library/Caches/go-build`
- Whether Full Disk Access is needed to list `MobileSync/Backup`
- Finder's `empty trash` behaviour with locked items on current macOS
