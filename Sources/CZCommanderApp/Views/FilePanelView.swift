import SwiftUI
import Combine
import AppKit
import CZCommanderCore

public struct FilePanelView: View {
    @ObservedObject var viewModel: CommanderViewModel
    @ObservedObject var panel: PanelController
    @State private var editablePathText: String = ""
    @State private var lastClickedItemID: String? = nil
    @State private var lastClickTimestamp: TimeInterval = 0
    @State private var gridRenameTimer = GridRenameTimer()
    @FocusState private var renameFieldFocused: Bool
    @State private var gridMenuTarget: FileContextMenuTarget? = nil
    @State private var gridDragTracker = GridRightDragTracker()

    private var isActive: Bool {
        viewModel.activeSide == panel.side
    }

    private var palette: CommanderThemePalette {
        viewModel.themePalette
    }


    public init(viewModel: CommanderViewModel, panel: PanelController) {
        self.viewModel = viewModel
        self.panel = panel
    }

    public var body: some View {
        VStack(spacing: 0) {
            if viewModel.showDriveBar {
                driveSelectorBar
            }
            folderTabsBar
            pathHeaderBar
            if panel.activeTab.viewMode != .thumbnails && panel.activeTab.viewMode != .brief {
                columnHeaderBar
            }
            fileListContent
            if panel.isQuickFilterVisible || !panel.activeTab.quickFilter.isEmpty {
                quickFilterBar
            }
            panelStatusBar
        }
        .background(palette.panelBackground.swiftUIColor)
        // The active panel is shown by its stronger header colour only (no frame), like Total Commander.
        .overlay(Rectangle().stroke(palette.dividerColor.swiftUIColor, lineWidth: 0.5))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            // Collect every dropped file, then copy them as one job with the progress dialog.
            let group = DispatchGroup()
            let lock = NSLock()
            var paths: [String] = []
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { lock.lock(); paths.append(url.path); lock.unlock() }
                    group.leave()
                }
            }
            let destination = self.panel.currentPath
            group.notify(queue: .main) {
                // Dropped back where they came from: nothing to copy.
                let incoming = paths.filter { ($0 as NSString).deletingLastPathComponent != destination }
                guard !incoming.isEmpty else { return }
                FileOperationManager.shared.copy(incoming, to: destination)
            }
            return true
        }
    }

    private func focusThisPanel() {
        if viewModel.activeSide != panel.side {
            viewModel.activeSide = panel.side
        }
        if !panel.isEditingPath && !panel.isQuickFilterVisible && panel.inlineRenameItemID == nil {
            CommanderKeyboardRouter.shared.focusKeyCaptureView()
        }
    }

    private func handleInstantRowClick(item: FileItem, index: Int) {
        let wasFocused = isActive && panel.cursorIndex == index
        focusThisPanel()
        gridRenameTimer.cancel()
        let now = ProcessInfo.processInfo.systemUptime
        let sameItem = lastClickedItemID == item.id
        let gap = now - lastClickTimestamp
        let isDouble = sameItem && gap < NSEvent.doubleClickInterval
        lastClickedItemID = item.id
        lastClickTimestamp = isDouble ? 0 : now
        panel.setCursor(to: index, scrollIntoView: false)
        if isDouble {
            panel.enterItem(item)
        } else if wasFocused && sameItem && SlowClickRename.isSlowSecondClick(sincePrevious: gap) {
            // Slow double click: rename, unless a real double click follows
            let panel = self.panel
            gridRenameTimer.schedule(after: NSEvent.doubleClickInterval) {
                panel.beginInlineRename(itemID: item.id)
            }
        }
    }

    /// Right click in grid views: short = toggle selection, hold = context menu, drag = range select.
    private func gridRightClickCatcher(item: FileItem, index: Int) -> RightClickSelectCatcher {
        RightClickSelectCatcher(
            itemID: item.id,
            tracker: gridDragTracker,
            onToggle: {
                focusThisPanel()
                gridRenameTimer.cancel()
                panel.setCursor(to: index, scrollIntoView: false)
                guard !item.isParentDirectoryEntry else { return nil }
                let newState = !panel.selectedItemIDs.contains(item.id)
                panel.setSelection(ofItemID: item.id, selected: newState)
                return newState
            },
            onSetSelection: { id, state in
                panel.setSelection(ofItemID: id, selected: state)
                if let idx = panel.displayedItems.firstIndex(where: { $0.id == id }) {
                    panel.setCursor(to: idx, scrollIntoView: false)
                }
            },
            menuProvider: {
                focusThisPanel()
                panel.setCursor(to: index, scrollIntoView: false)
                let target = gridMenuTarget ?? FileContextMenuTarget(viewModel: viewModel, panel: panel)
                target.viewModel = viewModel
                target.panel = panel
                gridMenuTarget = target
                return target.menu(for: item)
            }
        )
    }

    // MARK: - 1. Drive & Volume Bar (No ScrollView delay -> 0ms click response)

    private var driveSelectorBar: some View {
        VStack(spacing: 2) {
            // Adapts to panel width: full labels -> shortcut icons -> shortcuts in a menu -> scrollable. Never truncates volume names.
            ViewThatFits(in: .horizontal) {
                driveButtonsRow(shortcutTitles: true)
                driveButtonsRow(shortcutTitles: false)
                driveButtonsRow(shortcutTitles: false, shortcutsAsMenu: true)
                ScrollView(.horizontal, showsIndicators: false) {
                    driveButtonsRow(shortcutTitles: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.top, 4)

            HStack {
                if let vol = panel.currentVolumeInfo {
                    Text(vol.tcHeaderDescription())
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundColor(palette.regularFileText.swiftUIColor)
                        .lineLimit(1)
                }
                Spacer()
                Button("\\") {
                    focusThisPanel()
                    panel.goToRoot()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(palette.toolbarBackground.swiftUIColor)
                .overlay(Rectangle().stroke(palette.dividerColor.swiftUIColor, lineWidth: 1))
                .foregroundColor(palette.regularFileText.swiftUIColor)
                .help("Root directory (/)")

                Button("..") {
                    focusThisPanel()
                    panel.goUp()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(palette.toolbarBackground.swiftUIColor)
                .overlay(Rectangle().stroke(palette.dividerColor.swiftUIColor, lineWidth: 1))
                .foregroundColor(palette.regularFileText.swiftUIColor)
                .help("Parent folder (Backspace)")
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 3)
        }
        .background(palette.toolbarBackground.swiftUIColor)
    }

    private func driveButtonsRow(shortcutTitles: Bool, shortcutsAsMenu: Bool = false) -> some View {
        HStack(spacing: 3) {
            ForEach(viewModel.mountedVolumes) { vol in
                let isCurrentVol = panel.currentPath == vol.path || (vol.path != "/" && panel.currentPath.hasPrefix(vol.path))
                Button {
                    focusThisPanel()
                    panel.navigateTo(path: vol.path)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: vol.sfSymbolName)
                            .font(.system(size: 10, weight: .semibold))
                        Text(vol.name)
                            .font(.system(size: 11, weight: .bold))
                            .lineLimit(1)
                    }
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(Rectangle().fill(isCurrentVol ? palette.activeHeaderBackground.swiftUIColor : palette.toolbarBackground.swiftUIColor))
                    .overlay(Rectangle().stroke(palette.dividerColor.swiftUIColor, lineWidth: 1))
                    .foregroundColor(isCurrentVol ? palette.activeHeaderText.swiftUIColor : palette.regularFileText.swiftUIColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(vol.tcHeaderDescription())
            }

            Divider()
                .frame(height: 14)

            if shortcutsAsMenu {
                Menu {
                    ForEach(viewModel.quickShortcuts) { sc in
                        Button {
                            focusThisPanel()
                            panel.navigateTo(path: sc.path)
                        } label: {
                            Label(sc.name, systemImage: sc.sfSymbolName)
                        }
                    }
                } label: {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 10))
                        .foregroundColor(palette.regularFileText.swiftUIColor)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .overlay(Rectangle().stroke(palette.dividerColor.swiftUIColor, lineWidth: 0.8))
                .help("Quick folders")
            } else {
            ForEach(viewModel.quickShortcuts) { sc in
                Button {
                    focusThisPanel()
                    panel.navigateTo(path: sc.path)
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: sc.sfSymbolName)
                            .font(.system(size: 9.5))
                        if shortcutTitles {
                            Text(sc.name)
                                .font(.system(size: 10, weight: .semibold))
                                .lineLimit(1)
                        }
                    }
                    .fixedSize()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Rectangle().fill(palette.toolbarBackground.swiftUIColor))
                    .overlay(Rectangle().stroke(palette.dividerColor.swiftUIColor, lineWidth: 0.8))
                    .foregroundColor(palette.regularFileText.swiftUIColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(sc.path)
            }
            }
        }
        .fixedSize()
    }

    // MARK: - 2. Folder Tabs Bar (Cmd+T, Cmd+W, Lock)

    private var folderTabsBar: some View {
        HStack(spacing: 2) {
            ForEach(Array(panel.tabs.enumerated()), id: \.element.id) { (idx, tab) in
                let isSelectedTab = idx == panel.activeTabIndex
                HStack(spacing: 4) {
                    Text(tab.displayTitle)
                        .font(.system(size: 11, weight: isSelectedTab ? .bold : .medium))
                        .lineLimit(1)
                    if panel.tabs.count > 1 && tab.lockState == .unlocked {
                        Button {
                            panel.closeTab(at: idx)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    isSelectedTab
                        ? palette.panelBackground.swiftUIColor
                        : palette.statusBarBackground.swiftUIColor
                )
                .foregroundColor(palette.regularFileText.swiftUIColor)
                .overlay(
                    Rectangle()
                        .stroke(palette.dividerColor.swiftUIColor, lineWidth: 1)
                )
                .help(tabTooltip(tab))
                .onTapGesture {
                    focusThisPanel()
                    panel.selectTab(at: idx)
                }
                .contextMenu { tabContextMenu(idx: idx, tab: tab) }
            }

            Spacer()

            Menu {
                ForEach(PanelViewMode.userSelectable, id: \.self) { mode in
                    Button {
                        focusThisPanel()
                        panel.activeTab.viewMode = mode
                        panel.reload()
                    } label: {
                        HStack {
                            Text(mode.title)
                            if panel.activeTab.viewMode == mode {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "rectangle.grid.1x2")
                    .font(.system(size: 11))
                    .foregroundColor(palette.regularFileText.swiftUIColor)
                    .padding(.horizontal, 4)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Switch View Mode")

            Button {
                focusThisPanel()
                panel.addNewTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(palette.regularFileText.swiftUIColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
            .help("New Tab (Cmd+T)")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(palette.statusBarBackground.swiftUIColor)
    }

    private func tabTooltip(_ tab: FolderTab) -> String {
        switch tab.lockState {
        case .unlocked:
            return tab.currentPath
        case .locked:
            return "Locked tab: " + tab.lockedBasePath
        case .lockedDirChangesAllowed:
            var text = "Locked (dir changes allowed): " + tab.lockedBasePath
            if tab.isAwayFromLockedBase {
                text += "\n" + "Currently: " + tab.currentPath
            }
            return text
        }
    }

    /// Total Commander style folder tab menu.
    @ViewBuilder
    private func tabContextMenu(idx: Int, tab: FolderTab) -> some View {
        let otherPanel = panel.side == .left ? viewModel.rightPanel : viewModel.leftPanel
        Button("New Tab (Cmd+T)") {
            panel.selectTab(at: idx)
            panel.addNewTab()
        }
        Button("Duplicate Tab") {
            panel.selectTab(at: idx)
            panel.duplicateActiveTab()
        }
        Button("Open as New Tab in Other Panel") {
            otherPanel.addNewTab(atPath: tab.currentPath)
        }
        Button("Rename Tab…") {
            viewModel.activeSheet = .renameTab(side: panel.side, index: idx)
        }
        Divider()
        Picker("Lock", selection: Binding(
            get: { tab.lockState },
            set: { panel.setTabLock(at: idx, to: $0) }
        )) {
            Text("Not locked").tag(TabLockState.unlocked)
            Text("Locked  (*)").tag(TabLockState.locked)
            Text("Locked, but directory changes allowed  (!)").tag(TabLockState.lockedDirChangesAllowed)
        }
        .pickerStyle(.inline)
        if tab.lockState != .unlocked && tab.currentPath != tab.lockedBasePath {
            Button("Back to Locked Folder") {
                panel.selectTab(at: idx)
                panel.returnLockedTabToBase()
            }
            Button("Lock to Current Folder") {
                panel.relockTabAtCurrentFolder(at: idx)
            }
        }
        Divider()
        Button("Close Tab (Cmd+W)") {
            panel.closeTab(at: idx, force: true)
        }
        .disabled(panel.tabs.count <= 1)
        Button("Close Other Tabs (locked stay)") {
            panel.closeOtherTabs(keeping: idx)
        }
        .disabled(panel.tabs.count <= 1)
        Button("Close All Unlocked Tabs") {
            panel.closeAllUnlockedTabs()
        }
        .disabled(panel.tabs.count <= 1)
        Button("Close Duplicate Tabs") {
            panel.closeDuplicateTabs()
        }
        .disabled(panel.tabs.count <= 1)
    }

    // MARK: - 3. Path Header & Directory Hotlist & History

    private var pathHeaderBar: some View {
        HStack(spacing: 4) {
            Button {
                focusThisPanel()
                panel.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(isActive ? palette.activeHeaderText.swiftUIColor : palette.inactiveHeaderText.swiftUIColor)
            }
            .buttonStyle(.plain)
            .disabled(panel.activeTab.historyBackStack.isEmpty)

            Button {
                focusThisPanel()
                panel.goForward()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(isActive ? palette.activeHeaderText.swiftUIColor : palette.inactiveHeaderText.swiftUIColor)
            }
            .buttonStyle(.plain)
            .disabled(panel.activeTab.historyForwardStack.isEmpty)

            if panel.isEditingPath {
                TextField("Path", text: $editablePathText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundColor(palette.activeHeaderText.swiftUIColor)
                    .onSubmit {
                        let target = (editablePathText as NSString).expandingTildeInPath
                        panel.isEditingPath = false
                        CommanderKeyboardRouter.shared.focusKeyCaptureView()
                        panel.navigateTo(path: target)
                    }
                Button("Go") {
                    let target = (editablePathText as NSString).expandingTildeInPath
                    panel.isEditingPath = false
                    CommanderKeyboardRouter.shared.focusKeyCaptureView()
                    panel.navigateTo(path: target)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(palette.activeHeaderText.swiftUIColor)
            } else {
                Text(headerPathDisplay)
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundColor(isActive ? palette.activeHeaderText.swiftUIColor : palette.inactiveHeaderText.swiftUIColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let now = ProcessInfo.processInfo.systemUptime
                        if (lastClickedItemID == "__path_header__") && ((now - lastClickTimestamp) < NSEvent.doubleClickInterval) {
                            lastClickTimestamp = 0
                            editablePathText = panel.currentPath
                            panel.isEditingPath = true
                        } else {
                            lastClickedItemID = "__path_header__"
                            lastClickTimestamp = now
                            focusThisPanel()
                        }
                    }
                    .help("Double-click to edit path directly")
            }

            // Directory Hotlist (`*` button)
            Menu {
                Button("➕ Add Current Directory") {
                    let name = (panel.currentPath as NSString).lastPathComponent
                    viewModel.hotlist.append(
                        DirectoryHotlistItem(
                            title: "📁 \(name.isEmpty ? "/" : name)",
                            sourcePath: panel.currentPath
                        )
                    )
                }
                Button("➕ Add Source + Target Pair") {
                    let sName = (panel.currentPath as NSString).lastPathComponent
                    let other = panel.side == .left ? viewModel.rightPanel : viewModel.leftPanel
                    let tName = (other.currentPath as NSString).lastPathComponent
                    viewModel.hotlist.append(
                        DirectoryHotlistItem(
                            title: "🔗 \(sName) ⇄ \(tName)",
                            sourcePath: panel.currentPath,
                            targetPath: other.currentPath
                        )
                    )
                }
                Divider()
                ForEach(viewModel.hotlist) { entry in
                    Button("\(entry.title)  [\(entry.sourcePath)]") {
                        focusThisPanel()
                        panel.navigateTo(path: entry.sourcePath)
                        if let tPath = entry.targetPath {
                            let other = panel.side == .left ? viewModel.rightPanel : viewModel.leftPanel
                            other.navigateTo(path: tPath)
                        }
                    }
                }
            } label: {
                Text("*")
                    .font(.system(size: 12, weight: .heavy, design: .monospaced))
                    .foregroundColor(isActive ? palette.activeHeaderText.swiftUIColor : palette.inactiveHeaderText.swiftUIColor)
                    .padding(.horizontal, 4)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Directory Hotlist")

            // Directory History Dropdown (Alt+Down)
            Menu {
                let history = Array(panel.activeTab.historyBackStack.reversed().prefix(15))
                if history.isEmpty {
                    Text("No history yet")
                } else {
                    ForEach(history, id: \.self) { histPath in
                        Button(histPath) {
                            focusThisPanel()
                            panel.navigateTo(path: histPath)
                        }
                    }
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(isActive ? palette.activeHeaderText.swiftUIColor : palette.inactiveHeaderText.swiftUIColor)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Directory History (Opt+Down)")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3.5)
        .background(isActive ? palette.activeHeaderBackground.swiftUIColor : palette.inactiveHeaderBackground.swiftUIColor)
    }

    private var headerPathDisplay: String {
        switch panel.activeTab.vfsMode {
        case .localDirectory(let path):
            let suffix = panel.activeTab.quickFilter.isEmpty ? "*.*" : panel.activeTab.quickFilter
            return (path == "/") ? "/*.*" : "\(path)/\(suffix)"
        case .archive(let arch, let sub):
            return sub.isEmpty ? "📦 \(arch)/*.*" : "📦 \(arch)/\(sub)/*.*"
        case .searchResults(let title, _, _):
            return "🔍 [\(title)]"
        case .remote(let profile, let remPath):
            return "🌐 \(profile.title):\(remPath)"
        }
    }

    // MARK: - 4. Column Header Bar (Name | Ext | Size | Date — NO Attr column)

    private var columnHeaderBar: some View {
        HStack(spacing: 0) {
            columnHeaderButton(.name, alignment: .leading)
                .padding(.leading, 6)
                .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle().fill(palette.dividerColor.swiftUIColor).frame(width: 1, height: 16)

            columnHeaderButton(.ext, alignment: .leading)
                .padding(.leading, 4)
                .frame(width: 62, alignment: .leading)

            Rectangle().fill(palette.dividerColor.swiftUIColor).frame(width: 1, height: 16)

            columnHeaderButton(.size, alignment: .trailing)
                .padding(.trailing, 6)
                .frame(width: 92, alignment: .trailing)

            Rectangle().fill(palette.dividerColor.swiftUIColor).frame(width: 1, height: 16)

            columnHeaderButton(.modificationDate, alignment: .leading)
                .padding(.leading, 6)
                .frame(width: 134, alignment: .leading)
        }
        .padding(.vertical, 3)
        .background(palette.toolbarBackground.swiftUIColor)
        .overlay(
            Rectangle().fill(palette.dividerColor.swiftUIColor).frame(height: 1),
            alignment: .bottom
        )
    }

    private func columnHeaderButton(_ col: PanelSortColumn, alignment: Alignment) -> some View {
        let isSorted = panel.activeTab.sortColumn == col
        let arrow = isSorted ? (panel.activeTab.sortAscending ? " ▲" : " ▼") : ""
        return Button {
            focusThisPanel()
            panel.toggleSort(by: col)
        } label: {
            Text(col.title + arrow)
                .font(.system(size: 11, weight: isSorted ? .bold : .semibold))
                .foregroundColor(palette.regularFileText.swiftUIColor)
                .frame(maxWidth: .infinity, alignment: alignment)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 5. File List Content (0.0ms Native AppKit NSTableView for Tabular Modes)

    @ViewBuilder
    private var fileListContent: some View {
        switch panel.activeTab.viewMode {
        case .thumbnails:
            CursorObserving(panel.cursorSignal) { thumbnailsGridView }
        case .brief:
            CursorObserving(panel.cursorSignal) { briefMultiColumnView }
        default:
            NativeFileTableView(viewModel: viewModel, panel: panel)
        }
    }

    /// In-place rename field used in the Thumbs grid (Enter / Esc handled by the keyboard router).
    private func gridRenameField(for item: FileItem) -> some View {
        TextField("", text: $panel.inlineRenameText)
            .textFieldStyle(.plain)
            .font(.system(size: 11, weight: .bold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 3)
            .background(Rectangle().fill(Color(nsColor: .textBackgroundColor)))
            .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
            .focused($renameFieldFocused)
            .onAppear { DispatchQueue.main.async { renameFieldFocused = true } }
            .onSubmit {
                viewModel.commitInlineRename()
                CommanderKeyboardRouter.shared.focusKeyCaptureView()
            }
    }

    // MARK: - Brief Multi-Column View (Cmd+F1)

    private var briefMultiColumnView: some View {
        let columns = [
            GridItem(.adaptive(minimum: 185, maximum: 260), spacing: 4)
        ]
        return ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 2) {
                ForEach(Array(panel.displayedItems.enumerated()), id: \.element.id) { (index, item) in
                    let isFocused = isActive && (index == panel.cursorIndex)
                    let isSelected = panel.selectedItemIDs.contains(item.id)
                    let textColor = palette.textColor(for: item, isSelected: isSelected, isFocused: isFocused)

                    HStack(spacing: 4) {
                        Image(systemName: palette.sfSymbol(for: item))
                            .font(.system(size: 11))
                            .foregroundColor(palette.iconColor(for: item, isSelected: isSelected, isFocused: isFocused))
                        Text(item.isDirectory ? "[\(item.name)]" : item.name)
                            .font(.system(size: viewModel.fontSize, weight: .bold))
                            .foregroundColor(textColor)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(isFocused ? palette.cursorBackground.swiftUIColor : (isSelected ? palette.selectedRowTint.swiftUIColor : palette.panelAlternateRow.swiftUIColor))
                    
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleInstantRowClick(item: item, index: index)
                    }
                    .overlay(gridRightClickCatcher(item: item, index: index))
                }
            }
            .padding(6)
        }
    }

    // MARK: - Thumbnails Grid View (Cmd+Shift+F1)

    private var thumbnailsGridView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Thumbnail size:")
                    .font(.system(size: 10.5))
                    .foregroundColor(palette.regularFileText.swiftUIColor)
                Slider(value: $panel.thumbnailSize, in: 64...180)
                    .frame(width: 120)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(palette.toolbarBackground.swiftUIColor)

            let cols = [GridItem(.adaptive(minimum: panel.thumbnailSize + 20, maximum: panel.thumbnailSize + 40), spacing: 8)]
            ScrollView {
                LazyVGrid(columns: cols, spacing: 8) {
                    ForEach(Array(panel.displayedItems.enumerated()), id: \.element.id) { (index, item) in
                        let isFocused = isActive && (index == panel.cursorIndex)
                        let isSelected = panel.selectedItemIDs.contains(item.id)
                        let textColor = palette.textColor(for: item, isSelected: isSelected, isFocused: isFocused)

                        VStack(spacing: 4) {
                            thumbnailPreviewImage(for: item)
                                .frame(width: panel.thumbnailSize, height: panel.thumbnailSize * 0.78)
                                .background(palette.panelAlternateRow.swiftUIColor)
                                

                            if panel.inlineRenameItemID == item.id {
                                gridRenameField(for: item)
                            } else {
                                Text(item.name)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(textColor)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }

                            Text(item.formattedSize(format: viewModel.sizeDisplayFormat))
                                .font(.system(size: 9.5).monospacedDigit())
                                .foregroundColor(palette.regularFileText.swiftUIColor)
                        }
                        .padding(6)
                        .background(isFocused ? palette.cursorBackground.swiftUIColor : (isSelected ? palette.selectedRowTint.swiftUIColor : Color.clear))
                        .overlay(
                            Rectangle()
                                .stroke(isFocused ? palette.cursorBorder.swiftUIColor : Color.clear, lineWidth: 1.5)
                        )
                        
                        .contentShape(Rectangle())
                        .onTapGesture {
                            handleInstantRowClick(item: item, index: index)
                        }
                        .overlay(gridRightClickCatcher(item: item, index: index))
                    }
                }
                .padding(8)
            }
        }
    }

    /// Real previews (QuickLook, Blackmagic RAW for .braw) generated in the background.
    private func thumbnailPreviewImage(for item: FileItem) -> some View {
        AsyncThumbnailView(
            item: item,
            pointSize: panel.thumbnailSize,
            fallbackSymbol: palette.sfSymbol(for: item),
            fallbackColor: palette.iconColor(for: item, isSelected: false, isFocused: false)
        )
    }

    // MARK: - 6. Quick Filter Bar (Cmd+S)

    private var quickFilterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundColor(palette.cursorBorder.swiftUIColor)
            Text("Search:")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(palette.regularFileText.swiftUIColor)
            TextField("Type to filter: any part of the name, or *.swift", text: Binding(
                get: { panel.activeTab.quickFilter },
                set: { newVal in
                    panel.activeTab.quickFilter = newVal
                    panel.applySortAndFilter()
                }
            ))
            .textFieldStyle(SquareTextFieldStyle())
            .font(.system(size: 11))

            Button {
                panel.activeTab.quickFilter = ""
                panel.isQuickFilterVisible = false
                CommanderKeyboardRouter.shared.focusKeyCaptureView()
                panel.applySortAndFilter()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(palette.toolbarBackground.swiftUIColor)
    }

    // MARK: - 7. Status Bar Footer (Without Attr)

    private var panelStatusBar: some View {
        HStack {
            // AppKit label updated straight from the cursor signal: selecting files must not
            // trigger a SwiftUI layout pass of the whole window.
            PanelStatusLabel(panel: panel, format: viewModel.sizeDisplayFormat, color: palette.regularFileText.nsColor)
                .frame(maxWidth: .infinity, minHeight: 15, maxHeight: 15)
            if let err = panel.errorMessage {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(palette.statusBarBackground.swiftUIColor)
        .overlay(
            Rectangle().fill(palette.dividerColor.swiftUIColor).frame(height: 1),
            alignment: .top
        )
    }
}


/// Holds the pending "slow double click" rename for grid views (reference type so @State keeps one instance).
final class GridRenameTimer {
    private var work: DispatchWorkItem?
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) {
        cancel()
        let item = DispatchWorkItem(block: action)
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
    func cancel() {
        work?.cancel()
        work = nil
    }
}


/// Re-renders only its content when the panel cursor or selection changes
/// (the rest of the panel UI is not invalidated by cursor moves).
struct CursorObserving<Content: View>: View {
    @ObservedObject var signal: PanelCursorSignal
    let content: () -> Content

    init(_ signal: PanelCursorSignal, @ViewBuilder content: @escaping () -> Content) {
        self.signal = signal
        self.content = content
    }

    var body: some View { content() }
}


/// Status bar summary as a fixed-size AppKit label that refreshes itself on cursor / selection
/// changes without involving SwiftUI.
struct PanelStatusLabel: NSViewRepresentable {
    let panel: PanelController
    let format: FileSizeDisplayFormat
    let color: NSColor

    final class Box: NSView {
        let label = NSTextField(labelWithString: "")
        var subscription: AnyCancellable?
        var refresh: (() -> Void)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.autoresizingMask = [.width]
            addSubview(label)
        }
        required init?(coder: NSCoder) { fatalError() }

        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 15) }
        override var isFlipped: Bool { true }
        override func layout() {
            super.layout()
            label.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        }
    }

    func makeNSView(context: Context) -> Box {
        let box = Box()
        box.subscription = panel.cursorSignal.changes.sink { [weak box] in box?.refresh?() }
        return box
    }

    func updateNSView(_ box: Box, context: Context) {
        let panel = self.panel, format = self.format
        box.label.textColor = color
        box.refresh = { [weak box] in
            let text = panel.statusBarText(format: format)
            if box?.label.stringValue != text { box?.label.stringValue = text }
        }
        box.refresh?()
    }
}
