<img src="docs/icon.png" width="128" alt="CZ.commander icon">

# CZ.commander

A native macOS dual-pane file manager for Apple Silicon, inspired by the classic Total Commander workflow: two panels, folder tabs, function-key operations and a toolbox of power tools. Built with SwiftUI + AppKit, no third-party dependencies.

> CZ.commander is an independent project and is not affiliated with or endorsed by Ghisler Software GmbH, the maker of Total Commander.

---

## Download

Get the latest **CZ.commander.app** from [Releases](https://github.com/ranczandras/CZ.commander/releases/latest): unzip it and move it to `/Applications`. The app is not notarized by Apple, so the first launch is blocked; open it once, then choose **System Settings → Privacy & Security → Open Anyway**.

CZ.commander checks GitHub for a newer release at launch (at most every 12 hours; can be turned off in Settings) and offers the download. **CZ.commander → Check for Updates…** checks right away.

Requires macOS 14 or later on Apple Silicon.

## Build & run

Requirements: macOS 14+, Apple Silicon, Xcode command line tools (Swift 6 toolchain).

```bash
./build_app.sh
open /Applications/CZ.commander.app
```

`build_app.sh` mirrors the sources to a local build cache (`~/.cache/czcommander-build`, override with `CZ_BUILD_DIR`), builds a release `arm64` binary, renders the app icon, assembles and signs the bundle on the local disk, then installs it to `/Applications` and copies it into the project folder.

Run the tests:

```bash
swift test --scratch-path ~/.cache/czcommander-build --disable-sandbox
```

### Code signing and macOS privacy prompts

If a code-signing identity named `CZ.commander Local Signing` exists in your keychain (override with `CZ_SIGN_ID`), the build signs with it; otherwise it falls back to ad-hoc signing. A stable identity keeps macOS privacy grants (removable volumes, Full Disk Access) across rebuilds. With ad-hoc signing every build looks like a new app to macOS, so the prompts come back.

A self-signed code-signing certificate is enough:

```bash
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 \
  -subj "/CN=CZ.commander Local Signing" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning"
openssl pkcs12 -export -inkey key.pem -in cert.pem -name "CZ.commander Local Signing" -out id.p12
security import id.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
```

### Window snapshots (development)

```bash
CZ_SNAPSHOT_DIR=/tmp CZ_SNAPSHOT_WIDTHS=1040,1500 /Applications/CZ.commander.app/Contents/MacOS/CZCommander
```

Resizes the main window to each width, saves `snapshot_<width>.png` and quits.

### Releasing

```bash
./release.sh 1.1.0 "What changed"
```

Bumps `VERSION`, builds and signs the app, tags `v1.1.0`, pushes and creates the GitHub release with the zipped app.

### Settings

Settings and tabs are stored in `~/Library/Application Support/CZ.commander/config.json`.

---

## Features

### Panels, tabs and views
- Left and right panels, vertical or horizontal split; `Tab` switches panels, `Cmd+U` swaps them, `Opt+E` makes target = source.
- Square-cornered window with its own title bar; the active panel is marked by its header colour.
- Folder tabs per panel (`Cmd+T` new, `Cmd+Shift+T` duplicate, `Cmd+W` close, `Ctrl+Tab` switch), Total Commander style locking:
  - **Locked (`*`)**: changing directory opens a new tab.
  - **Locked, but directory changes allowed (`!`)**: navigate freely; selecting the tab again jumps back to the locked folder.
  - Tab menu: rename, duplicate, open in other panel, relock to current folder, close other / unlocked / duplicate tabs.
- Drive bar with every mounted volume and free space, plus quick folders (`~`, Desktop, Downloads, Documents, Applications, `/`, Trash). Adapts to the panel width.
- Two view modes: **Full** (name, extension, size, date) and **Thumbnails**; the **View** toolbar button switches between them.
- **Hidden** toolbar button (`Cmd+H`) shows or hides hidden files.
- Directory hotlist and history, Quick View (`Cmd+Y`), separate folder tree (`Cmd+F8`).

### Mouse and keyboard
- Total Commander's Ctrl shortcuts use Cmd (Ctrl still works): `Cmd+M` Multi-Rename, `Cmd+T` / `Cmd+W` tabs, `Cmd+U` swap panels, `Cmd+H` hidden files, `Cmd+S` quick filter, `Cmd+A` select all, `Cmd+F3`…`Cmd+F6` sort. macOS keeps `Cmd+Q` (quit), `Cmd+F` (find), `Cmd+Tab` and `Cmd+Space`, so Quick View is `Cmd+Y`, FTP is `Cmd+Shift+F`, tab switching stays `Ctrl+Tab`.
- Every dialog opens inside the window with square corners; all controls are square.
- Right mouse button selects, like Total Commander: a short right click toggles the item, holding the button (~0.45 s) opens the context menu, right-dragging selects or deselects a range. Works in the list and in Thumbnails.
- Slow double click (a second click on the focused item) renames it in place, directly on the file name; `Shift+F6` does the same. Enter saves, Esc cancels.
- `Enter` opens folders, files and archives (`.zip`, `.tar`, `.tar.gz`, `.tar.bz2`, `.tar.xz`, `.7z`, `.iso`) as virtual folders; `Backspace` goes up and keeps the cursor on the folder you came from.
- `Space` selects and calculates folder sizes, `Alt+Shift+Enter` sizes every folder, `Insert` selects and moves down, `+` / `-` select / deselect by mask, `*` inverts, `/` restores the previous selection, `Shift+F2` compares directories.
- While the app is active it asks macOS for standard F1–F12 keys. Keyboards that handle Fn themselves (for example Logitech MX Keys) need their own Fn lock (`Fn+Esc`) or Logi Options+ settings.

### Function keys
- `F3` Lister: text (several encodings), binary, hex with search, and image / PDF viewer.
- `F4` internal editor (`Shift+F4` creates a new file).
- `F5` copy, `F6` move: target masks (`*.bak`), overwrite rules, CRC32 verification, background queue.
- `F7` new folder: several at once (`a|b|c`), nested paths, date / time templates.
- `F8` delete to Trash with a confirmation dialog; `Shift+F8` deletes permanently.

### Power tools
- **Multi-Rename** (`Cmd+M`): `[N]`, `[N1-5]`, `[E]`, `[C]`, `[YMD]`, `[hms]` masks, search & replace (incl. regex), case conversion, counters, live preview with conflict check, undo, presets.
- **Find Files** (`Alt+F7`): wildcard / regex names, text in files, date / size / attribute filters, duplicate finder (name, size, SHA-256), feed results to the panel.
- **Synchronize Directories**, **Compare by Content** (side-by-side text diff and binary hex diff).
- **Archives**: create and extract `.zip` / `.tar` variants, browse archives inside the panel.
- **Split & Combine** with `.crc` files, **checksums** (CRC32 `.sfv`, MD5, SHA-1, SHA-256, SHA-512), **encode / decode** (Base64, UUEncode, XXEncode).
- **Attributes**: POSIX permissions, macOS locked / hidden flags, Finder tags, timestamps.
- Properties & hash inspector, file list export (TXT, CSV, MD, HTML), disk space analyzer, FTP / SFTP connection manager.

## License

MIT, see [LICENSE](LICENSE).
