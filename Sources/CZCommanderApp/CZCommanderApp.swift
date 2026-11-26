import SwiftUI
import AppKit
import IOKit
import CZCommanderCore

@main
public struct CZCommanderMainApp: App {
    @StateObject private var viewModel = CommanderViewModel.shared
    @NSApplicationDelegateAdaptor(CommanderAppDelegate.self) private var appDelegate

    public init() {}

    public var body: some Scene {
        // The main window is a square-cornered borderless NSWindow created by the app delegate
        // (see SquareWindowChrome.swift); this scene only carries the menu bar commands.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await UpdateChecker.shared.check(userInitiated: true) }
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    MainWindowController.show()
                    viewModel.activeSheet = .settings
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
            commanderMenuCommands
        }
    }

    @CommandsBuilder
    private var commanderMenuCommands: some Commands {

        // 1. Files Menu
        CommandMenu("Files") {
            Button("View in Lister (F3 / 3 / Cmd+3)") {
                viewModel.triggerF3View()
            }
            .keyboardShortcut("3", modifiers: [.command])

            Button("Edit File (F4 / 4 / Cmd+4)") {
                viewModel.triggerF4Edit(createNew: false)
            }
            .keyboardShortcut("4", modifiers: [.command])

            Button("Create New File (Shift+F4)") {
                viewModel.triggerF4Edit(createNew: true)
            }
            Divider()
            Button("Copy (F5 / 5 / Cmd+5)") {
                viewModel.triggerF5Copy()
            }
            .keyboardShortcut("5", modifiers: [.command])

            Button("Move / Rename (F6 / 6 / Cmd+6)") {
                viewModel.triggerF6Move()
            }
            .keyboardShortcut("6", modifiers: [.command])

            Button("Create Directory (F7 / 7 / Cmd+7)") {
                viewModel.triggerF7NewFolder()
            }
            .keyboardShortcut("7", modifiers: [.command])

            Button("Delete to Trash (F8 / 8 / Cmd+8)") {
                viewModel.triggerF8Delete(permanent: false)
            }
            .keyboardShortcut("8", modifiers: [.command])

            Button("Permanent Delete (Shift+F8)") {
                viewModel.triggerF8Delete(permanent: true)
            }
            Divider()
            Button("Pack Files... (Alt+F5)") {
                viewModel.openPackDialog()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Button("Unpack Specific Files... (Alt+F9 / 9)") {
                viewModel.openUnpackDialog()
            }
            .keyboardShortcut("9", modifiers: [.command])

            Button("Test Archive(s) (Alt+Shift+F9)") {
                viewModel.testSelectedArchives()
            }
            Divider()
            Button("Multi-Rename Tool (Cmd+M)") {
                viewModel.openMultiRename()
            }
            .keyboardShortcut("m", modifiers: [.command])

            Button("Compare By Content...") {
                viewModel.openCompareByContent()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])

            Button("Change Attributes / Permissions...") {
                viewModel.openChangeAttributes()
            }
            Button("File Properties & Hash Inspector (Alt+Enter)...") {
                viewModel.openFilePropertiesInspector()
            }
            .keyboardShortcut("i", modifiers: [.command])

            Button("Export / Print File List...") {
                viewModel.openExportFileList()
            }
            Divider()
            Button("Split File...") {
                viewModel.openSplitFile()
            }
            Button("Combine Files...") {
                viewModel.openCombineFiles()
            }
            Button("Encode File (MIME, UUE, XXE)...") {
                viewModel.openEncodeFile()
            }
            Button("Decode File (MIME, UUE, XXE)...") {
                viewModel.openDecodeFile()
            }
            Divider()
            Button("Create Checksum File(s) (SFV, MD5, SHA)...") {
                viewModel.openChecksumCreator()
            }
            Button("Verify Checksums (from checksum files)...") {
                viewModel.openChecksumVerifier()
            }
        }

        // 2. Mark Menu
        CommandMenu("Mark") {
            Button("Select Group (+)") {
                viewModel.activeSheet = .selectGroupDialog(isSelect: true)
            }
            Button("Unselect Group (-)") {
                viewModel.activeSheet = .selectGroupDialog(isSelect: false)
            }
            Button("Select All (Cmd+A)") {
                viewModel.activePanel.selectAll()
            }
            Button("Unselect All") {
                viewModel.activePanel.deselectAll()
            }
            Button("Invert Selection (*)") {
                viewModel.activePanel.invertSelection()
            }
            Button("Select All With Same Extension") {
                viewModel.activePanel.selectSameExtension()
            }
            Button("Restore Selection (/)") {
                viewModel.activePanel.restoreSelection()
            }
            Divider()
            Button("Compare Directories (Shift+F2)") {
                viewModel.compareDirectoriesShiftF2()
            }
        }

        // 3. Commands Menu
        CommandMenu("Commands") {
            Button("Search / Find Files... (Alt+F7 / Cmd+F)") {
                viewModel.activeSheet = .findFiles(initialPath: viewModel.activePanel.currentPath)
            }
            .keyboardShortcut("f", modifiers: [.command])

            Button("Synchronize Directories...") {
                viewModel.activeSheet = .syncDirectories(
                    leftPath: viewModel.leftPanel.currentPath,
                    rightPath: viewModel.rightPanel.currentPath
                )
            }
            .keyboardShortcut("s", modifiers: [.command, .option])

            Button("Disk Space Analyzer...") {
                viewModel.activeSheet = .diskSpaceAnalyzer(path: viewModel.activePanel.currentPath)
            }
            .keyboardShortcut("d", modifiers: [.command, .option])

            Button("Calculate Occupied Space of All Subfolders") {
                viewModel.activePanel.calculateAllDirectorySizes()
            }

            Button("Background Transfer Manager...") {
                viewModel.activeSheet = .backgroundTransferManager
            }
            Divider()
            Button("Cleanup: Trash, Caches, Logs...") {
                MainWindowController.show()
                viewModel.activeSheet = .cleanup
            }
            .keyboardShortcut("k", modifiers: [.command, .option])

            Button("Empty Trash...") {
                MainWindowController.show()
                viewModel.activeSheet = .emptyTrash
            }
            .keyboardShortcut(.delete, modifiers: [.command, .shift])

            Button("YouTube Downloader...") {
                YouTubeDownloaderWindowController.show(viewModel: viewModel)
            }
            .keyboardShortcut("y", modifiers: [.command, .option])

            Button("Uninstall App...") {
                AppUninstallerWindowController.show(viewModel: viewModel)
            }
            .keyboardShortcut("u", modifiers: [.command, .option])

            Button("Startup Items...") {
                StartupWindowController.show(viewModel: viewModel)
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            Divider()
            Button("Source <-> Target (Cmd+U)") {
                viewModel.swapPanels()
            }
            .keyboardShortcut("u", modifiers: [.command])

            Button("Target = Source (Opt+E)") {
                viewModel.makeTargetEqualSource()
            }
            .keyboardShortcut("e", modifiers: [.command, .option])

            Divider()
            Button("Open New Tab (Cmd+T)") {
                viewModel.activePanel.addNewTab()
            }
            .keyboardShortcut("t", modifiers: [.command])

            Button("Duplicate Active Tab (Cmd+Shift+T)") {
                viewModel.activePanel.duplicateActiveTab()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
        }

        // 4. Net Menu
        CommandMenu("Net") {
            Button("FTP / SFTP Connect... (Cmd+Shift+F)") {
                viewModel.activeSheet = .remoteConnections
            }
            .keyboardShortcut("k", modifiers: [.command])

            Button("Disconnect Remote Session") {
                viewModel.activePanel.navigateTo(path: FileManager.default.homeDirectoryForCurrentUser.path)
            }
        }

        // 5. Show Menu
        CommandMenu("Show") {
            ForEach(PanelViewMode.userSelectable, id: \.self) { mode in
                Button(mode.title) {
                    viewModel.activePanel.activeTab.viewMode = mode
                    viewModel.activePanel.reload()
                }
            }
            Button("Switch View (Full / Thumbnails)") {
                viewModel.switchActiveViewMode()
            }
            Button(viewModel.showHiddenFiles
                   ? "Hide Hidden Files (Cmd+H)"
                   : "Show Hidden Files (Cmd+H)") {
                viewModel.showHiddenFiles.toggle()
            }
            Divider()
            Button("Quick View Panel (Cmd+Y)") {
                viewModel.isQuickViewActive.toggle()
            }
            .keyboardShortcut("y", modifiers: [.command])


            Divider()
            Button("Sort by Name (Cmd+F3)") {
                viewModel.activePanel.toggleSort(by: .name)
            }
            Button("Sort by Extension (Cmd+F4)") {
                viewModel.activePanel.toggleSort(by: .ext)
            }
            Button("Sort by Date/Time (Cmd+F5)") {
                viewModel.activePanel.toggleSort(by: .modificationDate)
            }
            Button("Sort by Size (Cmd+F6)") {
                viewModel.activePanel.toggleSort(by: .size)
            }
            Button("Unsorted (Cmd+F7)") {
                viewModel.activePanel.toggleSort(by: .unsorted)
            }
            Divider()
            Button("Toggle Vertical / Horizontal Split") {
                viewModel.isHorizontalSplit.toggle()
            }
            Button("Toggle Hidden Files (Cmd+H)") {
                viewModel.showHiddenFiles.toggle()
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])

            Button("Reread Source (F2 / Cmd+R)") {
                viewModel.refreshVolumes()
            }
            .keyboardShortcut("r", modifiers: [.command])
        }

        // 6. Configuration Menu
        CommandMenu("Configuration") {
            Menu("Theme") {
                ForEach(CommanderThemeID.allCases, id: \.self) { t in
                    Button(t.displayName) {
                        viewModel.themeID = t
                    }
                }
            }
            Divider()
            Button("Customize Button Bar...") {
                viewModel.activeSheet = .buttonBarEditor
            }
            Button("🔓 Grant Full Disk Access...") {
                viewModel.activeSheet = .fullDiskAccess
            }
            Button("Options / Configuration...") {
                viewModel.activeSheet = .settings
            }
            Divider()
            Button("Save Settings & Tabs Now") {
                viewModel.saveCurrentConfiguration()
            }
        }
    }
}

// MARK: - Dedicated AppKit FirstResponder View for Total Commander Key Capture

public struct CommanderKeyCaptureView: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> CommanderKeyCaptureNSView {
        let view = CommanderKeyCaptureNSView()
        CommanderKeyboardRouter.shared.keyCaptureView = view
        return view
    }

    public func updateNSView(_ nsView: CommanderKeyCaptureNSView, context: Context) {
        CommanderKeyboardRouter.shared.keyCaptureView = nsView
    }
}

public final class CommanderKeyCaptureNSView: NSView {
    public override var acceptsFirstResponder: Bool { true }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let win = self.window else { return }
            if !(win.firstResponder is NSTextView) {
                win.makeFirstResponder(self)
            }
        }
    }

    public override func keyDown(with event: NSEvent) {
        if CommanderKeyboardRouter.shared.processEvent(event) {
            return
        }
        super.keyDown(with: event)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if CommanderKeyboardRouter.shared.processEvent(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - AppKit Delegate & Centralized Keyboard Router


// MARK: - Hardware Function Key (F1..F12 without Fn) Auto-Switcher for Apple Silicon

@_silgen_name("IOHIDSetCFTypeParameter")
private func TC_IOHIDSetCFTypeParameter(_ handle: io_connect_t, _ key: CFString, _ parameter: CFTypeRef) -> kern_return_t

@_silgen_name("IOHIDCopyCFTypeParameter")
private func TC_IOHIDCopyCFTypeParameter(_ handle: io_connect_t, _ key: CFString, _ parameter: UnsafeMutablePointer<CFTypeRef?>) -> kern_return_t

public final class MacFunctionKeyModeController: @unchecked Sendable {
    public static let shared = MacFunctionKeyModeController()

    private var savedUserMode: Int = 0
    private var isOverridden: Bool = false
    public var autoEnableStandardFKeys: Bool = true

    private init() {
        // Ensure we restore system HIDFKeyMode even on SIGTERM / SIGINT
        signal(SIGTERM) { _ in
            MacFunctionKeyModeController.shared.restoreSystemFunctionKeyMode()
            exit(0)
        }
        signal(SIGINT) { _ in
            MacFunctionKeyModeController.shared.restoreSystemFunctionKeyMode()
            exit(0)
        }
    }

    public func enableStandardFunctionKeysForApp() {
        guard autoEnableStandardFKeys, !isOverridden else { return }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 1, &connect) == KERN_SUCCESS else { return }
        defer { IOServiceClose(connect) }

        if !isOverridden {
            var ref: CFTypeRef? = nil
            if TC_IOHIDCopyCFTypeParameter(connect, "HIDFKeyMode" as CFString, &ref) == KERN_SUCCESS,
               let num = ref as? NSNumber {
                savedUserMode = num.intValue
            } else {
                savedUserMode = 0
            }
        }

        if savedUserMode != 1 {
            _ = TC_IOHIDSetCFTypeParameter(connect, "HIDFKeyMode" as CFString, NSNumber(value: 1))
            isOverridden = true
        }
    }

    public func restoreSystemFunctionKeyMode() {
        guard isOverridden else { return }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 1, &connect) == KERN_SUCCESS else { return }
        defer { IOServiceClose(connect) }

        _ = TC_IOHIDSetCFTypeParameter(connect, "HIDFKeyMode" as CFString, NSNumber(value: savedUserMode))
        isOverridden = false
    }
}

@MainActor
public final class CommanderAppDelegate: NSObject, NSApplicationDelegate {
    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        MainWindowController.show()
        NSApp.activate(ignoringOtherApps: true)
        MacFunctionKeyModeController.shared.enableStandardFunctionKeysForApp()
        CommanderKeyboardRouter.shared.installMonitorsIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            CommanderKeyboardRouter.shared.focusKeyCaptureView()
        }
        Self.runSnapshotModeIfRequested()
        if ProcessInfo.processInfo.environment["CZ_SNAPSHOT_DIR"] == nil,
           !UpdateChecker.shared.runSelfTestIfRequested() {
            UpdateChecker.shared.checkAtLaunchIfDue()
        }
    }

    /// Dev/QA helper: `CZ_SNAPSHOT_DIR=/path CZ_SNAPSHOT_WIDTHS=1040,1500 open CZ.commander.app`
    /// resizes the main window to each width, saves `snapshot_<width>.png` there, then quits.
    private static func runSnapshotModeIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["CZ_SNAPSHOT_DIR"] else { return }
        let widths = (env["CZ_SNAPSHOT_WIDTHS"] ?? "1040,1500").split(separator: ",").compactMap { Double($0) }
        func shoot(_ index: Int) {
            guard let window = MainWindowController.window else { NSApp.terminate(nil); return }
            guard index < widths.count else { shootDialogs(window, 0); return }
            if index == 0 {
                let info = "contentView=\(String(describing: window.contentView.map { type(of: $0) })) subviews=\(window.contentView?.subviews.count ?? 0) key=\(window.isKeyWindow) main=\(window.isMainWindow) borderless=\(window.styleMask.contains(.titled) == false) resizable=\(window.styleMask.contains(.resizable)) firstResponder=\(String(describing: type(of: window.firstResponder as Any)))\n"
                try? info.write(toFile: (dir as NSString).appendingPathComponent("window_info.txt"), atomically: true, encoding: .utf8)
            }
            window.setFrame(NSRect(x: 40, y: 120, width: widths[index], height: 720), display: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let url = URL(fileURLWithPath: dir).appendingPathComponent("snapshot_\(Int(widths[index])).png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                }
                shoot(index + 1)
            }
        }
        // CZ_SNAPSHOT_DIALOGS=multiRename,findFiles,settings,mkdir also captures those dialogs.
        let dialogs = (env["CZ_SNAPSHOT_DIALOGS"] ?? "").split(separator: ",").map(String.init)
        // CZ_BENCH=1: time 300 cursor steps + 100 selection toggles, each followed by a full display pass.
        func runBench(_ window: NSWindow) {
            let vm = CommanderViewModel.shared
            let panel = vm.activePanel
            panel.setCursor(to: 0)
            func step(_ body: () -> Void) -> Double {
                let t = CFAbsoluteTimeGetCurrent()
                body()
                // Drain everything queued by the change (coalesced signals, SwiftUI updates) before timing stops
                var drained = false
                DispatchQueue.main.async { drained = true }
                while !drained { RunLoop.main.run(mode: .default, before: .distantFuture) }
                window.displayIfNeeded()
                return (CFAbsoluteTimeGetCurrent() - t) * 1000
            }
            var moves: [Double] = []
            for i in 0..<(env["CZ_BENCH"] == "long" ? 3000 : 300) { moves.append(step { panel.moveCursor(by: i % 60 < 30 ? 1 : -1) }) }
            var toggles: [Double] = []
            for _ in 0..<100 { toggles.append(step { panel.toggleSelectionAtCursor(advanceCursor: true, calculateDirSizeOnSpace: false) }) }
            func stats(_ a: [Double]) -> String {
                let s = a.sorted()
                return String(format: "avg %.2f ms, p50 %.2f, p95 %.2f, max %.2f", a.reduce(0, +) / Double(a.count), s[s.count / 2], s[Int(Double(s.count) * 0.95)], s.last ?? 0)
            }
            let line = "items=\(panel.displayedItems.count) cursor: \(stats(moves)) | select: \(stats(toggles))\n"
            if let h = FileHandle(forWritingAtPath: (dir as NSString).appendingPathComponent("window_info.txt")) {
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
            }
        }

        var benchDone = false
        func shootDialogs(_ window: NSWindow, _ i: Int) {
            if i == 0, env["CZ_BENCH"] != nil, !benchDone {
                // Run from a timer (not a main-queue block) so the nested run loop can drain the main queue.
                benchDone = true
                Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        runBench(window)
                        shootDialogs(window, 0)
                    }
                }
                return
            }
            guard i < dialogs.count else { NSApp.terminate(nil); return }
            let vm = CommanderViewModel.shared
            let path = vm.activePanel.currentPath
            switch dialogs[i] {
            case "multiRename": vm.activeSheet = .multiRename(items: Array(vm.activePanel.displayedItems.filter { !$0.isParentDirectoryEntry }.prefix(5)))
            case "findFiles": vm.activeSheet = .findFiles(initialPath: path)
            case "settings": vm.activeSheet = .settings
            case "youtube": YouTubeDownloaderWindowController.show(viewModel: vm)
            case "startup": StartupWindowController.show(viewModel: vm)
            case "uninstaller":
                AppUninstallerWindowController.show(viewModel: vm)
                // CZ_UNINSTALL_APP=/Applications/X.app preselects an app (read-only preview).
                if let app = env["CZ_UNINSTALL_APP"] { AppUninstallerSession.shared.select(path: app) }
            case "mkdir": vm.activeSheet = .mkdirDialog(baseDir: path)
            case "copy": vm.activeSheet = .copyDialog(sources: Array(vm.activePanel.displayedItems.suffix(2)), destinationDir: vm.inactivePanel.currentPath, isMove: false)
            default: break
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (dialogs[i] == "uninstaller" ? 6.0 : 1.0)) {
                let shotWindow = AuxWindow.window(dialogs[i] == "youtube" ? "youtube" : dialogs[i]) ?? window
                if let view = shotWindow.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let url = URL(fileURLWithPath: dir).appendingPathComponent("dialog_\(dialogs[i]).png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                    let fr = "\(dialogs[i]): firstResponder=\(String(describing: window.firstResponder.map { type(of: $0) }))\n"
                    if let h = FileHandle(forWritingAtPath: (dir as NSString).appendingPathComponent("window_info.txt")) {
                        h.seekToEndOfFile(); h.write(fr.data(using: .utf8)!); h.closeFile()
                    }
                }
                vm.activeSheet = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { shootDialogs(window, i + 1) }
            }
        }
        // CZ_SNAPSHOT_PATH=/dir opens that folder in the active panel; CZ_SNAPSHOT_VIEW=thumbs switches to Thumbnails.
        if let path = env["CZ_SNAPSHOT_PATH"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let panel = CommanderViewModel.shared.activePanel
                panel.navigateTo(path: path)
                if env["CZ_SNAPSHOT_VIEW"] == "thumbs" {
                    panel.activeTab.viewMode = .thumbnails
                    panel.reload()
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (env["CZ_SNAPSHOT_PATH"] == nil ? 2.0 : 5.0)) { shoot(0) }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowController.show()
        return true
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        MacFunctionKeyModeController.shared.enableStandardFunctionKeysForApp()
        CommanderKeyboardRouter.shared.focusKeyCaptureView()
    }

    public func applicationWillResignActive(_ notification: Notification) {
        MacFunctionKeyModeController.shared.restoreSystemFunctionKeyMode()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        MacFunctionKeyModeController.shared.restoreSystemFunctionKeyMode()
    }
}

@MainActor
public final class CommanderKeyboardRouter {
    public static let shared = CommanderKeyboardRouter()

    public weak var viewModel: CommanderViewModel?
    public weak var keyCaptureView: CommanderKeyCaptureNSView?
    private var keyMonitor: Any?
    private var lastHandledTimestamp: TimeInterval = -1

    public func installMonitorsIfNeeded() {
        guard keyMonitor == nil else { return }
        MacFunctionKeyModeController.shared.enableStandardFunctionKeysForApp()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MacFunctionKeyModeController.shared.enableStandardFunctionKeysForApp()
            Task { @MainActor in
                CommanderKeyboardRouter.shared.focusKeyCaptureView()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MacFunctionKeyModeController.shared.restoreSystemFunctionKeyMode()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self else { return event }
            if self.processEvent(event) {
                return nil
            }
            return event
        }
    }

    public func focusKeyCaptureView() {
        MacFunctionKeyModeController.shared.enableStandardFunctionKeysForApp()
        let vm = viewModel ?? CommanderViewModel.shared
        guard vm.activeSheet == nil,
              !vm.leftPanel.isEditingPath,
              !vm.rightPanel.isEditingPath,
              !vm.leftPanel.isQuickFilterVisible,
              !vm.rightPanel.isQuickFilterVisible,
              vm.leftPanel.inlineRenameItemID == nil,
              vm.rightPanel.inlineRenameItemID == nil else {
            return
        }
        if let capture = keyCaptureView, let win = capture.window {
            if win.firstResponder !== capture {
                win.makeFirstResponder(capture)
            }
        }
    }

    public func processEvent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        if abs(event.timestamp - lastHandledTimestamp) < 0.0001 {
            return true
        }

        let vm = viewModel ?? CommanderViewModel.shared

        // Tool windows (YouTube, Uninstaller) handle their own keys.
        if let win = event.window, AuxWindow.isAuxWindow(win) {
            return false
        }

        // 1. If a modal sheet is open: allow Esc to close it, otherwise let the sheet handle keys
        if vm.activeSheet != nil {
            if event.keyCode == 53 { // Esc
                vm.activeSheet = nil
                lastHandledTimestamp = event.timestamp
                focusKeyCaptureView()
                return true
            }
            return false
        }

        let panel = vm.activePanel
        let otherPanel = vm.inactivePanel

        // 2. If inline rename (Shift+F6) is active
        if panel.inlineRenameItemID != nil || otherPanel.inlineRenameItemID != nil {
            if event.keyCode == 53 { // Esc cancels inline rename
                panel.inlineRenameItemID = nil
                otherPanel.inlineRenameItemID = nil
                lastHandledTimestamp = event.timestamp
                focusKeyCaptureView()
                return true
            }
            if event.keyCode == 36 || event.keyCode == 76 { // Return commits inline rename
                vm.commitInlineRename()
                lastHandledTimestamp = event.timestamp
                focusKeyCaptureView()
                return true
            }
            return false
        }

        // 3. If user is editing the path bar directly
        if panel.isEditingPath || otherPanel.isEditingPath {
            if event.keyCode == 53 { // Esc cancels path edit
                panel.isEditingPath = false
                otherPanel.isEditingPath = false
                lastHandledTimestamp = event.timestamp
                focusKeyCaptureView()
                return true
            }
            return false
        }

        // 4. If Quick Filter (Cmd+S) is open: allow navigation and F-keys to work, while text keys go to the filter field
        if panel.isQuickFilterVisible || otherPanel.isQuickFilterVisible {
            if event.keyCode == 53 { // Esc closes quick filter
                panel.activeTab.quickFilter = ""
                panel.isQuickFilterVisible = false
                otherPanel.activeTab.quickFilter = ""
                otherPanel.isQuickFilterVisible = false
                panel.applySortAndFilter()
                lastHandledTimestamp = event.timestamp
                focusKeyCaptureView()
                return true
            }
            let navAndFnKeyCodes: Set<UInt16> = [
                126, 125, 116, 121, 115, 119, 36, 76, 48,
                120, 99, 118, 96, 97, 98, 100, 101
            ]
            if !navAndFnKeyCodes.contains(event.keyCode) && event.specialKey == nil {
                return false
            }
        }

        if event.keyCode == 53 { // Esc cancels any running background folder size calculation
            panel.cancelAllSizeCalculations()
            otherPanel.cancelAllSizeCalculations()
            lastHandledTimestamp = event.timestamp
            return true
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isShift = flags.contains(.shift)
        let isOption = flags.contains(.option)
        let isControl = flags.contains(.control)
        let isCommand = flags.contains(.command)
        let special = event.specialKey

        // MARK: - A. Function Keys (F2..F9 via both specialKey and keyCode)

        if special == .f2 || event.keyCode == 120 {
            lastHandledTimestamp = event.timestamp
            if isShift {
                vm.compareDirectoriesShiftF2()
            } else {
                vm.refreshVolumes()
            }
            return true
        }

        if special == .f3 || event.keyCode == 99 {
            lastHandledTimestamp = event.timestamp
            if isControl || isCommand {
                panel.toggleSort(by: .name)
            } else {
                vm.triggerF3View()
            }
            return true
        }

        if special == .f4 || event.keyCode == 118 {
            lastHandledTimestamp = event.timestamp
            if isControl || isCommand {
                panel.toggleSort(by: .ext)
            } else {
                vm.triggerF4Edit(createNew: isShift)
            }
            return true
        }

        if special == .f5 || event.keyCode == 96 {
            lastHandledTimestamp = event.timestamp
            if isControl || isCommand {
                panel.toggleSort(by: .modificationDate)
            } else if isOption {
                vm.openPackDialog()
            } else {
                vm.triggerF5Copy(inSameDirectory: isShift)
            }
            return true
        }

        if special == .f6 || event.keyCode == 97 {
            lastHandledTimestamp = event.timestamp
            if isControl || isCommand {
                panel.toggleSort(by: .size)
            } else {
                vm.triggerF6Move(inlineRename: isShift)
            }
            return true
        }

        if special == .f7 || event.keyCode == 98 {
            lastHandledTimestamp = event.timestamp
            if isControl || isCommand {
                panel.toggleSort(by: .unsorted)
            } else if isOption {
                vm.activeSheet = .findFiles(initialPath: panel.currentPath)
            } else {
                vm.triggerF7NewFolder()
            }
            return true
        }

        if special == .f8 || event.keyCode == 100 {
            lastHandledTimestamp = event.timestamp
            vm.triggerF8Delete(permanent: isShift)
            return true
        }

        if special == .f9 || event.keyCode == 101 {
            lastHandledTimestamp = event.timestamp
            if isOption && isShift {
                vm.testSelectedArchives()
            } else {
                vm.openUnpackDialog()
            }
            return true
        }

        // MARK: - B. Navigation & Selection Keys (via both specialKey and keyCode)

        if special == .tab || special == .backTab || event.keyCode == 48 {
            lastHandledTimestamp = event.timestamp
            if isControl {
                if isShift {
                    panel.selectPreviousTab()
                } else {
                    panel.selectNextTab()
                }
            } else {
                vm.switchActivePanel()
            }
            return true
        }

        if special == .upArrow || event.keyCode == 126 {
            lastHandledTimestamp = event.timestamp
            if isCommand {
                panel.goUp()
            } else if isShift {
                panel.toggleSelectionAtCursor(advanceCursor: false, calculateDirSizeOnSpace: false)
                panel.moveCursor(by: -1)
            } else {
                panel.moveCursor(by: -1)
            }
            return true
        }

        if special == .downArrow || event.keyCode == 125 {
            lastHandledTimestamp = event.timestamp
            if isCommand {
                panel.enterFocusedItem()
            } else if isShift {
                panel.toggleSelectionAtCursor(advanceCursor: true, calculateDirSizeOnSpace: false)
            } else {
                panel.moveCursor(by: 1)
            }
            return true
        }

        if special == .leftArrow || event.keyCode == 123 {
            lastHandledTimestamp = event.timestamp
            if isOption {
                panel.goBack()
            } else if panel.activeTab.viewMode == .brief || panel.activeTab.viewMode == .thumbnails {
                panel.moveCursor(by: -4)
            } else {
                vm.activeSide = .left
            }
            return true
        }

        if special == .rightArrow || event.keyCode == 124 {
            lastHandledTimestamp = event.timestamp
            if isOption {
                panel.goForward()
            } else if panel.activeTab.viewMode == .brief || panel.activeTab.viewMode == .thumbnails {
                panel.moveCursor(by: 4)
            } else {
                vm.activeSide = .right
            }
            return true
        }

        if special == .pageUp || event.keyCode == 116 {
            lastHandledTimestamp = event.timestamp
            panel.moveCursor(by: -18)
            return true
        }

        if special == .pageDown || event.keyCode == 121 {
            lastHandledTimestamp = event.timestamp
            panel.moveCursor(by: 18)
            return true
        }

        if special == .home || event.keyCode == 115 {
            lastHandledTimestamp = event.timestamp
            panel.setCursor(to: 0)
            return true
        }

        if special == .end || event.keyCode == 119 {
            lastHandledTimestamp = event.timestamp
            panel.setCursor(to: max(0, panel.displayedItems.count - 1))
            return true
        }

        if special == .carriageReturn || special == .enter || event.keyCode == 36 || event.keyCode == 76 {
            lastHandledTimestamp = event.timestamp
            if isOption && isShift {
                panel.calculateAllDirectorySizes()
            } else if isOption {
                vm.openFilePropertiesInspector()
            } else {
                panel.enterFocusedItem()
            }
            return true
        }

        if special == .delete || event.keyCode == 51 {
            lastHandledTimestamp = event.timestamp
            if isCommand {
                vm.triggerF8Delete(permanent: isShift)
            } else {
                panel.goUp()
            }
            return true
        }

        if special == .deleteForward || event.keyCode == 117 {
            lastHandledTimestamp = event.timestamp
            vm.triggerF8Delete(permanent: isShift)
            return true
        }

        if event.keyCode == 49 { // Space
            lastHandledTimestamp = event.timestamp
            panel.toggleSelectionAtCursor(advanceCursor: isControl, calculateDirSizeOnSpace: true)
            return true
        }

        if special == .insert || special == .help || event.keyCode == 114 {
            lastHandledTimestamp = event.timestamp
            panel.toggleSelectionAtCursor(advanceCursor: true, calculateDirSizeOnSpace: false)
            return true
        }

        // MARK: - C. Number Key Equivalents for F2..F9 on MacBooks (2..9, Cmd+2..9, Cmd+2..9, Opt+5/7/9)

        if let charsIgnoring = event.charactersIgnoringModifiers {
            switch charsIgnoring {
            case "2":
                lastHandledTimestamp = event.timestamp
                if isShift {
                    vm.compareDirectoriesShiftF2()
                } else {
                    vm.refreshVolumes()
                }
                return true
            case "3":
                lastHandledTimestamp = event.timestamp
                if isControl {
                    panel.toggleSort(by: .name)
                } else {
                    vm.triggerF3View()
                }
                return true
            case "4":
                lastHandledTimestamp = event.timestamp
                if isControl {
                    panel.toggleSort(by: .ext)
                } else {
                    vm.triggerF4Edit(createNew: isShift)
                }
                return true
            case "5":
                lastHandledTimestamp = event.timestamp
                if isControl {
                    panel.toggleSort(by: .modificationDate)
                } else if isOption {
                    vm.openPackDialog()
                } else {
                    vm.triggerF5Copy(inSameDirectory: isShift)
                }
                return true
            case "6":
                lastHandledTimestamp = event.timestamp
                if isControl {
                    panel.toggleSort(by: .size)
                } else {
                    vm.triggerF6Move(inlineRename: isShift)
                }
                return true
            case "7":
                lastHandledTimestamp = event.timestamp
                if isOption {
                    vm.activeSheet = .findFiles(initialPath: panel.currentPath)
                } else {
                    vm.triggerF7NewFolder()
                }
                return true
            case "8":
                lastHandledTimestamp = event.timestamp
                vm.triggerF8Delete(permanent: isShift)
                return true
            case "9":
                lastHandledTimestamp = event.timestamp
                if isOption && isShift {
                    vm.testSelectedArchives()
                } else {
                    vm.openUnpackDialog()
                }
                return true
            default:
                break
            }
        }

        // MARK: - D. Cmd (or Ctrl) Total Commander Shortcuts

        // Total Commander's Ctrl shortcuts work with Cmd (macOS style) and with Ctrl.
        // Cmd+Q (quit) and Cmd+F (find) stay macOS standard: Quick View is Cmd+Y, FTP is Cmd+Shift+F.
        if (isControl || isCommand) && !(isControl && isCommand) {
            if let chars = event.charactersIgnoringModifiers?.lowercased() {
                switch chars {
                case "q" where isControl, "y" where isCommand:
                    lastHandledTimestamp = event.timestamp
                    vm.isQuickViewActive.toggle()
                    return true
                case "b":
                    lastHandledTimestamp = event.timestamp
                    vm.executeInternalCommand("cm_DirBranch")
                    return true
                case "m":
                    lastHandledTimestamp = event.timestamp
                    vm.openMultiRename()
                    return true
                case "f" where isControl || isShift:
                    lastHandledTimestamp = event.timestamp
                    vm.activeSheet = .remoteConnections
                    return true
                case "s":
                    lastHandledTimestamp = event.timestamp
                    panel.isQuickFilterVisible.toggle()
                    return true
                case "t":
                    lastHandledTimestamp = event.timestamp
                    panel.addNewTab()
                    return true
                case "w":
                    lastHandledTimestamp = event.timestamp
                    panel.closeTab()
                    return true
                case "u":
                    lastHandledTimestamp = event.timestamp
                    vm.swapPanels()
                    return true
                case "h":
                    lastHandledTimestamp = event.timestamp
                    vm.showHiddenFiles.toggle()
                    return true
                case "a":
                    lastHandledTimestamp = event.timestamp
                    panel.selectAll()
                    return true
                default:
                    break
                }
            }
        }

        // Single-character selection shortcuts (+, -, *, /)
        if !isCommand && !isControl && !isOption, let chars = event.characters {
            switch chars {
            case "+", "=":
                lastHandledTimestamp = event.timestamp
                vm.activeSheet = .selectGroupDialog(isSelect: true)
                return true
            case "-":
                lastHandledTimestamp = event.timestamp
                vm.activeSheet = .selectGroupDialog(isSelect: false)
                return true
            case "*":
                lastHandledTimestamp = event.timestamp
                panel.invertSelection()
                return true
            case "/":
                lastHandledTimestamp = event.timestamp
                panel.restoreSelection()
                return true
            default:
                break
            }
        }

        return false
    }
}
