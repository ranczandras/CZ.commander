import SwiftUI
import AppKit
import CZCommanderCore

public struct MainCommanderWindowView: View {
    @ObservedObject var viewModel: CommanderViewModel

    private var palette: CommanderThemePalette { viewModel.themePalette }

    public init(viewModel: CommanderViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            SquareTitleBar(palette: palette)
            UpdateBanner(checker: UpdateChecker.shared)

            if viewModel.showButtonBar {
                topButtonBar
            }

            if let banner = viewModel.statusBannerMessage {
                HStack {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.yellow)
                    Text(banner)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                    Spacer()
                    Button {
                        viewModel.statusBannerMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.blue.opacity(0.85))
            }

            // Main Workspace Area: Optional Tree Sidebar + Dual Panels (or QuickView)
            HStack(spacing: 0) {

                if viewModel.isHorizontalSplit {
                    VSplitView {
                        leftPaneOrQuickView
                        rightPaneOrQuickView
                    }
                } else {
                    HSplitView {
                        leftPaneOrQuickView
                        rightPaneOrQuickView
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if viewModel.showFunctionKeyBar {
                functionKeyBar
            }
        }
        .background(palette.panelBackground.swiftUIColor)
        .overlay(Rectangle().stroke(palette.dividerColor.swiftUIColor, lineWidth: 1))
        .ignoresSafeArea()
        // Speed over eye candy: no implicit animations or fades anywhere in the app.
        .transaction { t in
            t.animation = nil
            t.disablesAnimations = true
        }
        .preferredColorScheme(palette.isLightTheme ? .light : .dark)
        .onAppear {
            DispatchQueue.main.async {
                CommanderKeyboardRouter.shared.focusKeyCaptureView()
            }
        }
        // Dialogs are shown inside the window with a square frame (macOS sheets are always rounded).
        .overlay {
            if let sheet = viewModel.activeSheet {
                SquareModalHost(onCancel: { CommanderDialog.close(viewModel) }) {
                    sheetContent(for: sheet)
                }
                .id(sheet.id)
            }
        }
        .squareControls()
    }

    @ViewBuilder
    private var leftPaneOrQuickView: some View {
        if viewModel.isQuickViewActive && viewModel.activeSide == .right {
            QuickViewPaneView(viewModel: viewModel)
                .frame(minWidth: 320, minHeight: 200)
        } else {
            FilePanelView(viewModel: viewModel, panel: viewModel.leftPanel)
                .frame(minWidth: 320, minHeight: 200)
        }
    }

    @ViewBuilder
    private var rightPaneOrQuickView: some View {
        if viewModel.isQuickViewActive && viewModel.activeSide == .left {
            QuickViewPaneView(viewModel: viewModel)
                .frame(minWidth: 320, minHeight: 200)
        } else {
            FilePanelView(viewModel: viewModel, panel: viewModel.rightPanel)
                .frame(minWidth: 320, minHeight: 200)
        }
    }

    // MARK: - Top Button Bar

    private var topButtonBar: some View {
        HStack(spacing: 3) {
            // Adapts to window width: icon + name -> icon over small caption -> icon only -> scrollable icons. Never wraps text.
            ViewThatFits(in: .horizontal) {
                toolbarButtonsRow(showTitles: true)
                toolbarButtonsRow(showTitles: true, stacked: true)
                toolbarButtonsRow(showTitles: false)
                ScrollView(.horizontal, showsIndicators: false) {
                    toolbarButtonsRow(showTitles: false)
                }
            }
            .padding(.leading, 6)
            .layoutPriority(-1)

            Spacer(minLength: 4)

            // Swap & Equal Panels Quick Buttons
            Button {
                CommanderKeyboardRouter.shared.focusKeyCaptureView()
                viewModel.swapPanels()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 11, weight: .bold))
                    .padding(5)
                    .background(Rectangle().fill(palette.toolbarBackground.swiftUIColor))
                            .overlay(Rectangle().stroke(palette.dividerColor.swiftUIColor, lineWidth: 0.8))
                    .foregroundColor(palette.regularFileText.swiftUIColor)
            }
            .buttonStyle(.plain)
            .help("Swap Panels (Cmd+U)")

            Button {
                CommanderKeyboardRouter.shared.focusKeyCaptureView()
                viewModel.makeTargetEqualSource()
            } label: {
                Text("=")
                    .font(.system(size: 12, weight: .heavy, design: .monospaced))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Rectangle().fill(palette.toolbarBackground.swiftUIColor))
                            .overlay(Rectangle().stroke(palette.dividerColor.swiftUIColor, lineWidth: 0.8))
                    .foregroundColor(palette.regularFileText.swiftUIColor)
            }
            .buttonStyle(.plain)
            .help("Target = Source")

            // Theme Quick Menu
            Menu {
                ForEach(CommanderThemeID.allCases, id: \.self) { t in
                    Button {
                        viewModel.themeID = t
                    } label: {
                        HStack {
                            Text(t.displayName)
                            if viewModel.themeID == t {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "paintpalette.fill")
                    .font(.system(size: 11.5))
                    .padding(5)
                    .foregroundColor(palette.directoryText.swiftUIColor)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Switch Theme")

            // Full Disk Access Quick Button
            Button {
                viewModel.activeSheet = .fullDiskAccess
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: FullDiskAccessHelper.hasFullDiskAccess() ? "lock.open.fill" : "lock.shield.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text("Full Access")
                        .font(.system(size: 10.5, weight: .bold))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Rectangle().fill(FullDiskAccessHelper.hasFullDiskAccess() ? Color.green.opacity(0.2) : Color.orange.opacity(0.25)))
                .foregroundColor(palette.regularFileText.swiftUIColor)
            }
            .buttonStyle(.plain)
            .help("Configure macOS Full Disk Access")

            // Settings Button
            Button {
                viewModel.activeSheet = .settings
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12))
                    .padding(5)
                    .foregroundColor(palette.regularFileText.swiftUIColor)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
            .help("Configuration")
        }
        .padding(.vertical, 4)
        .background(palette.toolbarBackground.swiftUIColor)
        .overlay(Divider(), alignment: .bottom)
    }

    /// Live icon for toggle-style toolbar commands.
    private func toolbarIcon(for btn: ButtonBarItem) -> String {
        switch btn.command {
        case "cm_SwitchHidSys": return viewModel.showHiddenFiles ? "h.square.fill" : "h.square"
        case "cm_SwitchView": return viewModel.activePanel.activeTab.viewMode == .thumbnails ? "square.grid.2x2" : "list.bullet.rectangle"
        default: return btn.iconName
        }
    }

    /// Strong orange so an active toggle (e.g. hidden files shown) is obvious at a glance.
    static let toggleOnColor = Color(red: 0.96, green: 0.45, blue: 0.05)

    private func toolbarIsOn(_ btn: ButtonBarItem) -> Bool {
        btn.command == "cm_SwitchHidSys" && viewModel.showHiddenFiles
    }

    private func toolbarHelp(for btn: ButtonBarItem) -> String {
        switch btn.command {
        case "cm_SwitchHidSys":
            return viewModel.showHiddenFiles
                ? "Hidden files shown – click to hide (Cmd+H)"
                : "Hidden files hidden – click to show (Cmd+H)"
        case "cm_SwitchView":
            return "Switch view: Full ⇄ Thumbnails"
        default:
            return btn.title
        }
    }

    private func toolbarButtonsRow(showTitles: Bool, stacked: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 3) {
            ForEach(viewModel.buttonBarItems) { btn in
                Button {
                    CommanderKeyboardRouter.shared.focusKeyCaptureView()
                    viewModel.executeInternalCommand(btn.command)
                } label: {
                    Group {
                        if stacked {
                            VStack(spacing: 2) {
                                Image(systemName: toolbarIcon(for: btn))
                                    .font(.system(size: 12, weight: .semibold))
                                    .frame(height: 14)
                                Text(toolbarShortTitle(btn.title))
                                    .font(.system(size: 9, weight: .medium))
                                    .lineLimit(1)
                            }
                            .frame(minWidth: 30)
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: toolbarIcon(for: btn))
                                    .font(.system(size: 11.5, weight: .semibold))
                                if showTitles {
                                    Text(toolbarShortTitle(btn.title))
                                        .font(.system(size: 10.5, weight: .medium))
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    .fixedSize()
                    .padding(.horizontal, showTitles ? (stacked ? 4 : 7) : 6)
                    .padding(.vertical, 4)
                    .background(Rectangle().fill(toolbarIsOn(btn) ? Self.toggleOnColor : palette.toolbarBackground.swiftUIColor))
                    .overlay(Rectangle().stroke(toolbarIsOn(btn) ? Self.toggleOnColor : palette.dividerColor.swiftUIColor, lineWidth: 0.8))
                    .foregroundColor(toolbarIsOn(btn) ? .white : palette.regularFileText.swiftUIColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(toolbarHelp(for: btn))
            }
        }
        .fixedSize()
    }

    // MARK: - Bottom Function Key Bar (F3..F8 + Power Shortcuts)

    private var functionKeyBar: some View {
        HStack(spacing: 2) {
            fnButton(key: "F3", label: "View") {
                viewModel.triggerF3View()
            }
            fnButton(key: "F4", label: "Edit") {
                viewModel.triggerF4Edit()
            }
            fnButton(key: "F5", label: "Copy") {
                viewModel.triggerF5Copy()
            }
            fnButton(key: "F6", label: "Move") {
                viewModel.triggerF6Move()
            }
            fnButton(key: "F7", label: "New Folder") {
                viewModel.triggerF7NewFolder()
            }
            fnButton(key: "F8", label: "Delete") {
                viewModel.triggerF8Delete(permanent: false)
            }
            fnButton(key: "Alt+F5", label: "Pack") {
                viewModel.openPackDialog()
            }
            fnButton(key: "Alt+F7", label: "Find") {
                viewModel.activeSheet = .findFiles(initialPath: viewModel.activePanel.currentPath)
            }
            fnButton(key: "Cmd+M", label: "Multi-Rename") {
                viewModel.openMultiRename()
            }
            fnButton(key: "Sync", label: "Sync") {
                viewModel.activeSheet = .syncDirectories(leftPath: viewModel.leftPanel.currentPath, rightPath: viewModel.rightPanel.currentPath)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(palette.statusBarBackground.swiftUIColor)
        .overlay(Divider(), alignment: .top)
    }

    private func fnButton(key: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            CommanderKeyboardRouter.shared.focusKeyCaptureView()
            action()
        } label: {
            HStack(spacing: 4) {
                Text(key)
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundColor(palette.directoryText.swiftUIColor)
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(palette.regularFileText.swiftUIColor)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(Rectangle().fill(palette.toolbarBackground.swiftUIColor))
            .overlay(Rectangle().stroke(palette.dividerColor.swiftUIColor, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sheet Router

    @ViewBuilder
    private func sheetContent(for sheet: ActiveCommanderSheet) -> some View {
        switch sheet {
        case .lister(let filePath, let mode):
            ListerWindowSheetView(viewModel: viewModel, filePath: filePath, initialMode: mode)
        case .editor(let filePath, let isNew):
            InternalEditorSheetView(viewModel: viewModel, filePath: filePath, isNewFile: isNew)
        case .copyDialog(let sources, let dest, let isMove):
            CopyMoveSheetView(viewModel: viewModel, sources: sources, destinationDir: dest, isMove: isMove)
        case .mkdirDialog(let baseDir):
            MkDirSheetView(viewModel: viewModel, baseDir: baseDir)
        case .packDialog(let sources, let dest):
            PackFilesSheetView(viewModel: viewModel, sources: sources, destinationDir: dest)
        case .unpackDialog(let archives, let dest):
            UnpackFilesSheetView(viewModel: viewModel, archives: archives, destinationDir: dest)
        case .multiRename(let items):
            MultiRenameToolSheetView(viewModel: viewModel, items: items)
        case .findFiles(let initialPath):
            FindFilesSheetView(viewModel: viewModel, initialPath: initialPath)
        case .syncDirectories(let leftPath, let rightPath):
            SynchronizeDirectoriesSheetView(viewModel: viewModel, leftPath: leftPath, rightPath: rightPath)
        case .compareByContent(let leftPath, let rightPath):
            CompareByContentSheetView(viewModel: viewModel, leftPath: leftPath, rightPath: rightPath)
        case .checksumCreate(let files):
            ChecksumCreateSheetView(viewModel: viewModel, files: files)
        case .checksumVerify(let manifestPath):
            ChecksumVerifySheetView(viewModel: viewModel, manifestPath: manifestPath)
        case .splitFile(let file, let dest):
            SplitCombineEncodeSheetViews.SplitSheet(viewModel: viewModel, file: file, destinationDir: dest)
        case .combineFiles(let part, let dest):
            SplitCombineEncodeSheetViews.CombineSheet(viewModel: viewModel, partOrCRC: part, destinationDir: dest)
        case .encodeFile(let file, let dest):
            SplitCombineEncodeSheetViews.EncodeSheet(viewModel: viewModel, file: file, destinationDir: dest)
        case .decodeFile(let file, let dest):
            SplitCombineEncodeSheetViews.DecodeSheet(viewModel: viewModel, file: file, destinationDir: dest)
        case .changeAttributes(let items):
            ChangeAttributesSheetView(viewModel: viewModel, items: items)
        case .remoteConnections:
            RemoteConnectionsSheetView(viewModel: viewModel)
        case .diskSpaceAnalyzer(let path):
            DiskSpaceAnalyzerSheetView(viewModel: viewModel, path: path)
        case .backgroundTransferManager:
            BackgroundTransferManagerSheetView(viewModel: viewModel)
        case .selectGroupDialog(let isSelect):
            SelectGroupSheetView(viewModel: viewModel, isSelect: isSelect)
        case .fileProperties(let item):
            FilePropertiesSheetView(viewModel: viewModel, item: item)
        case .exportFileList(let items, let dirPath):
            ExportFileListSheetView(viewModel: viewModel, items: items, directoryPath: dirPath)
        case .buttonBarEditor:
            ButtonBarEditorSheetView(viewModel: viewModel)
        case .fullDiskAccess:
            FullDiskAccessSheetView(viewModel: viewModel)
        case .settings:
            SettingsSheetView(viewModel: viewModel)
        case .deleteConfirm(let items, let permanent, let secureWipe):
            DeleteConfirmSheetView(viewModel: viewModel, items: items, permanent: permanent, secureWipe: secureWipe)
        case .renameTab(let side, let index):
            RenameTabSheetView(viewModel: viewModel, panel: side == .left ? viewModel.leftPanel : viewModel.rightPanel, index: index)
        }
    }
}

/// Total Commander style delete confirmation (F8 / Delete). Enter = delete, Esc = cancel.
struct DeleteConfirmSheetView: View {
    @ObservedObject var viewModel: CommanderViewModel
    let items: [FileItem]
    let permanent: Bool
    let secureWipe: Bool


    private var question: String {
        let files = items.filter { !$0.isDirectory }.count
        let dirs = items.count - files
        if items.count == 1, let only = items.first {
            let kind = only.isDirectory ? "the folder" : "the file"
            return permanent
                ? "Really delete \(kind) PERMANENTLY?"
                : "Move \(kind) to the Trash?"
        }
        let what = "\(files) file(s) and \(dirs) folder(s)"
        return permanent
            ? "Really delete the selected \(what) PERMANENTLY?"
            : "Move the selected \(what) to the Trash?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: permanent ? "exclamationmark.triangle.fill" : "trash")
                    .font(.system(size: 22))
                    .foregroundColor(permanent ? .red : .accentColor)
                Text(permanent ? "Permanent delete"
                               : "Delete (Trash)")
                    .font(.system(size: 14, weight: .bold))
            }
            Text(question)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items.prefix(8), id: \.id) { item in
                    Text((item.isDirectory ? "📁 " : "📄 ") + item.name)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if items.count > 8 {
                    Text("… and \(items.count - 8) more")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Rectangle().fill(Color.primary.opacity(0.05)))
            .overlay(Rectangle().stroke(Color.primary.opacity(0.15), lineWidth: 1))

            HStack {
                Spacer()
                Button("Cancel (Esc)") {
                    close()
                }
                .keyboardShortcut(.cancelAction)
                Button(permanent ? "Delete permanently (Enter)"
                                 : "Delete (Enter)") {
                    let toDelete = items
                    close()
                    viewModel.performDelete(items: toDelete, permanent: permanent, secureWipe: secureWipe)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(SquareProminentButtonStyle())
            }
        }
        .padding(18)
        .frame(width: 420)
    }

    private func close() {
        CommanderDialog.close(viewModel)
    }
}


/// Rename a folder tab (empty name = show the folder name).
struct RenameTabSheetView: View {
    @ObservedObject var viewModel: CommanderViewModel
    let panel: PanelController
    let index: Int
    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Tab")
                .font(.system(size: 14, weight: .bold))
            TextField("Tab name (empty = folder name)", text: $name)
                .frame(width: 320)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel (Esc)") { CommanderDialog.close(viewModel) }
                    .keyboardShortcut(.cancelAction)
                Button("Save (Enter)", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(SquareProminentButtonStyle())
            }
        }
        .padding(18)
        .onAppear {
            if panel.tabs.indices.contains(index) { name = panel.tabs[index].customTitle ?? "" }
        }
    }

    private func save() {
        panel.renameTab(at: index, to: name)
        CommanderDialog.close(viewModel)
    }
}
