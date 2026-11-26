# Startup items: what is listed, what "off" means, and why

Reference for the Startup Items window (`Sources/CZCommanderCore/Tools/StartupEngine.swift`, `Sources/CZCommanderApp/Views/StartupWindow.swift`). Toolbar button **Startup**, menu Commands → Startup Items…, `Cmd+Opt+L`.

The window lists what macOS starts at login or boot and lets you turn single items off and on again. Turning an item off **never deletes anything**; ticking it again restores the previous behaviour. Fewer startup items means a faster login and less memory in use, but nothing here frees disk space (use Cleanup or the App Uninstaller for that).

## What is listed

| Source | Where | Can be changed here? | How "off" works |
|---|---|---|---|
| **Login Items** | System Settings → General → Login Items (apps that open at login) | yes, after macOS allows CZ.commander to control System Events | The item is removed from the list. Its name, path and "hide" flag are remembered in `~/Library/Application Support/CZ.commander/startup.json` so ticking it adds it back. |
| **Launch Agents of this user** | `~/Library/LaunchAgents/*.plist` | yes | `launchctl disable gui/<uid>/<label>` (launchd's own per-user override, no administrator rights), then `launchctl bootout` to stop it now. The plist is not touched. |
| **Launch Agents for all users** | `/Library/LaunchAgents/*.plist` | yes, for your account only | Same as above; other users are not affected, the plist stays where it is. |
| **Launch Daemons** | `/Library/LaunchDaemons/*.plist` | no, listed for information | They run as root before anyone logs in. Change them with `sudo launchctl disable system/<label>` or System Settings. |

Each row shows the app icon, the app name (derived from the program path, otherwise the launchd label), how it starts, whether it is running right now, and the program path. Badges:

- **running**: launchd has it running at this moment.
- **program missing**: the program the plist starts no longer exists. Harmless leftovers of uninstalled apps; turn them off here, or remove them with the App Uninstaller.
- **security / VPN**: the name looks like security, VPN or device-management software (words such as jamf, crowdstrike, sentinelone, kandji, intune, defender, sophos, malwarebytes, littlesnitch, vpn, wireguard, tailscale, anyconnect, globalprotect, zscaler). Turning these off can leave the Mac unprotected, drop the VPN, or be reported to your administrator. This is a name heuristic, so other software can be missed.
- **locked / admin only**: cannot be switched here (Apple items, daemons, unusual labels).
- **removed from the list**: a login item turned off here and remembered.

How an agent starts decides how it is shown: `RunAtLoad` or `KeepAlive` means "starts at login"; `StartInterval` / `StartCalendarInterval` "runs on a schedule"; `WatchPaths`, `QueueDirectories` or a conditional `KeepAlive` "starts on a file change or condition"; an agent that only offers a Mach service or socket is an **on-demand helper** of some app and is hidden unless you tick "Also show helpers that start only on demand" (turned-off helpers stay visible so they can be turned on again).

## What is safe to turn off

| Kind of item | Effect of turning it off |
|---|---|
| Updaters (Google, Adobe, Microsoft AutoUpdate, Zoom, Steam…) | The app no longer checks for updates by itself; it still can when you open it. Usually the best candidates. |
| Cloud sync (Dropbox, OneDrive, Google Drive) | Syncing stops until you start the app. |
| Menu-bar and utility apps (launchers, window managers, clipboard tools) | They simply are not there after login. |
| Chat, music, game launchers | They do not open at login. |
| Helpers marked on-demand | The owning app may lose a feature (for example a browser extension helper or a cloud-file provider). Leave them unless an app misbehaves. |
| Input methods, audio / driver helpers (Loopback, Rogue Amoeba, printer and scanner helpers), backup agents | Hardware or features stop working until the app is started. Know what it is first. |
| Security, VPN, management (badge above) | See the badge. Leave unless you know why. |

Because everything is reversible, the safe way to find out is to turn one item off, log out and in, and tick it again if something is missing.

## Safety rules in the engine

- Only plists directly inside `~/Library/LaunchAgents` and `/Library/LaunchAgents` are ever handled; the folder is checked again right before a command runs.
- Labels must be plain identifiers (letters, digits, `. _ - +`, no leading `-`); anything else is refused. Commands are run without a shell, with the label as one argument.
- AppleScript gets names and paths as `argv` arguments, never pasted into the script text.
- Apple items (`com.apple.*` labels or programs under `/System`), daemons and unusual labels are locked.
- After `disable` / `enable`, the result is checked by reading `launchctl print-disabled` back; a command that launchd did not record is reported as a failure. (Apple says launchctl's printed output is not a stable interface; if it stops looking like `"label" => state` the check is skipped and the message says so.)
- launchd's override database wins over the plist's own `Disabled` key, exactly like launchd itself.
- The plist, the program and the app are never modified, moved or deleted.

## What is not covered

- **Items registered through the newer background-item mechanism** (macOS 13+, "Allow in the Background" in System Settings → General → Login Items & Extensions). Another app cannot switch those; the window links to the settings page.
- Items an app starts itself through its own "Open at login" setting (most register as above; the switch is in the app).
- `/System/Library/LaunchAgents` and `LaunchDaemons` (macOS itself), kernel and system extensions, configuration-profile and MDM items, cron / `at` / periodic jobs, shell profiles (`~/.zshrc`).

## Not verified on a real Mac

Checked against documentation and community reports in this session, but not run on macOS 14/15/26:

- The Login Items listing, removal and re-adding through System Events (`name`, `path`, `hidden` of a login item; `delete (every login item whose name is …)`; `make login item at end with properties {path, hidden}`). One Jamf community report says adding a login item with `hidden` stopped working on Sonoma. If adding fails, the window shows the error, keeps the remembered entry and you can add the app back in System Settings.
- macOS asks once whether CZ.commander may control System Events (Automation); without that the Login Items section shows a notice and the agents still work.
- The exact text of `launchctl print-disabled` on your macOS version (both `=> disabled` and the older `=> true` are understood).

## Sources

- `man launchctl` and `man launchd.plist`: `disable` / `enable` / `bootout` / `print-disabled`, service targets (`gui/<uid>/<label>`), `RunAtLoad`, `KeepAlive`, `Disabled` ([launchctl(1)](https://leancrew.com/all-this/man/man1/launchctl.html))
- Apple Developer Forums on `print-disabled` output and service targets ([Where is service-target documented for launchctl?](https://developer.apple.com/forums/thread/16206))
- Apple, [Login Items AE sample (Read Me)](https://developer.apple.com/library/archive/samplecode/LoginItemsAE/Listings/Read_Me_About_LoginItemsAE_txt.html) and AppleScript users list threads on System Events login items; [Jamf community report](https://community.jamf.com/t5/jamf-pro/macos-sonoma-login-items-without-configuration-profile/m-p/303347/highlight/true) on Sonoma
- Apple Support, "Open items automatically when you log in to your Mac" and "Change Login Items & Extensions settings on Mac" for the System Settings side
