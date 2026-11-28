import SwiftUI
import Combine
import AppKit
import CZCommanderCore

public struct NativeFileTableView: NSViewRepresentable {
    @ObservedObject var viewModel: CommanderViewModel
    @ObservedObject var panel: PanelController

    public init(viewModel: CommanderViewModel, panel: PanelController) {
        self.viewModel = viewModel
        self.panel = panel
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel, panel: panel)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true

        let tableView = CommanderNSTableView()
        tableView.style = .plain
        tableView.headerView = nil
        tableView.rowHeight = 21
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .none
        tableView.focusRingType = .none
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "Name"
        nameCol.minWidth = 140
        nameCol.width = 280
        nameCol.resizingMask = .autoresizingMask
        tableView.addTableColumn(nameCol)

        let extCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ext"))
        extCol.title = "Ext"
        extCol.width = 62
        extCol.minWidth = 62
        extCol.maxWidth = 62
        extCol.resizingMask = []
        tableView.addTableColumn(extCol)

        let sizeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeCol.title = "Size"
        sizeCol.width = 92
        sizeCol.minWidth = 92
        sizeCol.maxWidth = 92
        sizeCol.resizingMask = []
        tableView.addTableColumn(sizeCol)

        let dateCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        dateCol.title = "Date"
        dateCol.width = 134
        dateCol.minWidth = 134
        dateCol.maxWidth = 134
        dateCol.resizingMask = []
        tableView.addTableColumn(dateCol)

        let coord = context.coordinator
        coord.tableView = tableView
        tableView.delegate = coord
        tableView.dataSource = coord

        tableView.onInstantRowPress = { [weak coord] row, clickCount, isRightClick in
            coord?.handleRowPress(row: row, clickCount: clickCount, isRightClick: isRightClick)
        }
        tableView.contextMenuProvider = { [weak coord] row in
            coord?.buildContextMenu(forRow: row)
        }
        tableView.onLeftMouseDown = { [weak coord] row, clickCount in
            coord?.noteLeftMouseDown(row: row, clickCount: clickCount)
        }
        tableView.onLeftMouseDragged = { [weak coord] in
            coord?.cancelPendingRename()
        }
        tableView.dragItemsProvider = { [weak coord] row in
            coord?.dragPayloads(forRow: row) ?? []
        }
        tableView.onRightClickSelect = { [weak coord] row in
            coord?.toggleSelection(ofRow: row)
        }
        tableView.onRightDragSelect = { [weak coord] row, state in
            coord?.setSelection(ofRow: row, selected: state)
        }

        scrollView.documentView = tableView
        // Cursor / selection changes bypass SwiftUI and update the affected rows directly.
        coord.cursorSubscription = panel.cursorSignal.changes.sink { [weak coord] in
            coord?.syncCursorAndSelection()
        }
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coord = context.coordinator
        coord.viewModel = viewModel
        coord.panel = panel
        coord.syncWithPanelState(scrollView: scrollView)
    }

    // MARK: - Coordinator

    @MainActor
    public final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        /// What to drag from `row`: the whole selection when the row is selected, otherwise just
        /// that row. Local files go as file URLs, Dropbox items as file promises; "..", archive
        /// entries and Dropbox's virtual rows are not draggable.
        func dragPayloads(forRow row: Int) -> [FileDragPayload] {
            let items = panel.displayedItems
            guard items.indices.contains(row) else { return [] }
            let pressed = items[row]
            func draggable(_ i: FileItem) -> Bool {
                !i.isParentDirectoryEntry && i.archiveContainerPath == nil && !i.fullPath.hasPrefix("dbx-action:")
                    && i.fullPath != DropboxLocation.sharedWithMe.fullPath
            }
            guard draggable(pressed) else { return [] }
            let selected = items.filter { panel.selectedItemIDs.contains($0.id) && draggable($0) }
            let list = selected.contains(where: { $0.id == pressed.id }) ? selected : [pressed]
            if panel.dropboxLocation != nil {
                return list.compactMap { DropboxIntegration.dragPayload(for: $0) }
            }
            return list.filter { FileManager.default.fileExists(atPath: $0.fullPath) }.map {
                FileDragPayload(writer: URL(fileURLWithPath: $0.fullPath) as NSURL,
                                icon: NSWorkspace.shared.icon(forFile: $0.fullPath))
            }
        }

        var viewModel: CommanderViewModel
        var panel: PanelController
        weak var tableView: CommanderNSTableView?

        private var cachedItems: [FileItem] = []
        private var lastCursorIndex: Int = -1
        private var lastSelectedIDs: Set<String> = []
        private var lastIsActive: Bool = false
        private var lastThemeID: CommanderThemeID = .windowsDefault
        private var lastFontSize: Double = 12.5
        private var lastSizeFormat: FileSizeDisplayFormat = .dynamicKMG
        private var lastScrollTargetID: String? = nil
        var cursorSubscription: AnyCancellable?

        init(viewModel: CommanderViewModel, panel: PanelController) {
            self.viewModel = viewModel
            self.panel = panel
        }

        func syncWithPanelState(scrollView: NSScrollView) {
            guard let tv = tableView else { return }
            let palette = viewModel.themePalette
            let bgNSColor = palette.panelBackground.nsColor
            if scrollView.backgroundColor != bgNSColor {
                scrollView.backgroundColor = bgNSColor
                tv.backgroundColor = bgNSColor
            }

            let isActive = (viewModel.activeSide == panel.side)
            let newItems = panel.displayedItems
            let newCursor = panel.cursorIndex
            let newSelected = panel.selectedItemIDs
            let themeChanged = (lastThemeID != viewModel.themeID) || (lastFontSize != viewModel.fontSize) || (lastSizeFormat != viewModel.sizeDisplayFormat)
            let itemsChanged = !areItemArraysMatching(cachedItems, newItems)

            if itemsChanged || themeChanged {
                cachedItems = newItems
                lastCursorIndex = newCursor
                lastSelectedIDs = newSelected
                lastIsActive = isActive
                lastThemeID = viewModel.themeID
                lastFontSize = viewModel.fontSize
                lastSizeFormat = viewModel.sizeDisplayFormat
                tv.reloadData()
            } else {
                syncCursorRows(tv, isActive: isActive)
            }

            syncInPlaceRename()
            syncScrollTarget(tv)
        }

        /// Fast path used on every cursor move / selection change (no item comparison, no SwiftUI).
        func syncCursorAndSelection() {
            guard let tv = tableView else { return }
            syncCursorRows(tv, isActive: viewModel.activeSide == panel.side)
            syncScrollTarget(tv)
        }

        private func syncScrollTarget(_ tv: NSTableView) {
            let newCursor = panel.cursorIndex
            if let scrollID = panel.scrollTargetID, scrollID != lastScrollTargetID {
                lastScrollTargetID = scrollID
                if newCursor >= 0 && newCursor < cachedItems.count {
                    tv.scrollRowToVisible(newCursor)
                }
            }
        }

        private func syncCursorRows(_ tv: NSTableView, isActive: Bool) {
            let newCursor = panel.cursorIndex
            let newSelected = panel.selectedItemIDs
            do {
                var rowsToReload = IndexSet()
                if lastCursorIndex != newCursor || lastIsActive != isActive {
                    if lastCursorIndex >= 0 && lastCursorIndex < cachedItems.count {
                        rowsToReload.insert(lastCursorIndex)
                    }
                    if newCursor >= 0 && newCursor < cachedItems.count {
                        rowsToReload.insert(newCursor)
                    }
                }
                if lastSelectedIDs != newSelected {
                    let diffIDs = lastSelectedIDs.symmetricDifference(newSelected)
                    for (idx, item) in cachedItems.enumerated() where diffIDs.contains(item.id) {
                        rowsToReload.insert(idx)
                    }
                }
                lastCursorIndex = newCursor
                lastSelectedIDs = newSelected
                lastIsActive = isActive

                if !rowsToReload.isEmpty {
                    let allCols = IndexSet(integersIn: 0..<tv.numberOfColumns)
                    tv.reloadData(forRowIndexes: rowsToReload, columnIndexes: allCols)
                    for r in rowsToReload {
                        if let rowView = tv.rowView(atRow: r, makeIfNecessary: false) as? CommanderRowView {
                            configureRowView(rowView, forRow: r)
                        }
                    }
                }
            }
        }

        private func areItemArraysMatching(_ a: [FileItem], _ b: [FileItem]) -> Bool {
            guard a.count == b.count else { return false }
            for i in 0..<a.count {
                if a[i].id != b[i].id
                    || a[i].name != b[i].name
                    || a[i].calculatedDirectorySize != b[i].calculatedDirectorySize
                    || a[i].isCalculatingSize != b[i].isCalculatingSize
                    || a[i].descriptionComment != b[i].descriptionComment {
                    return false
                }
            }
            return true
        }

        func handleRowPress(row: Int, clickCount: Int, isRightClick: Bool) {
            if viewModel.activeSide != panel.side {
                viewModel.activeSide = panel.side
            }
            CommanderKeyboardRouter.shared.focusKeyCaptureView()

            guard row >= 0 && row < cachedItems.count else { return }
            let item = cachedItems[row]

            // Immediate 0.0ms visual row update before SwiftUI cycle
            let oldCursor = panel.cursorIndex
            panel.setCursor(to: row, scrollIntoView: false)
            if let tv = tableView, oldCursor != row {
                var idxs = IndexSet([row])
                if oldCursor >= 0 && oldCursor < cachedItems.count {
                    idxs.insert(oldCursor)
                }
                let cols = IndexSet(integersIn: 0..<tv.numberOfColumns)
                tv.reloadData(forRowIndexes: idxs, columnIndexes: cols)
                for r in idxs {
                    if let rv = tv.rowView(atRow: r, makeIfNecessary: false) as? CommanderRowView {
                        configureRowView(rv, forRow: r)
                    }
                }
                lastCursorIndex = row
            }

            if clickCount == 2 && !isRightClick {
                panel.enterItem(item)
            }
        }

        /// Right click: put the cursor on the row and toggle its selection. Returns the new state.
        func toggleSelection(ofRow row: Int) -> Bool? {
            guard row >= 0 && row < cachedItems.count else { return nil }
            let item = cachedItems[row]
            guard !item.isParentDirectoryEntry else { return nil }
            let newState = !panel.selectedItemIDs.contains(item.id)
            setSelection(ofRow: row, selected: newState)
            return newState
        }

        func setSelection(ofRow row: Int, selected: Bool) {
            guard row >= 0 && row < cachedItems.count else { return }
            panel.setSelection(ofItemID: cachedItems[row].id, selected: selected)
            if let tv = tableView {
                tv.reloadData(forRowIndexes: IndexSet([row]), columnIndexes: IndexSet(integersIn: 0..<tv.numberOfColumns))
                if let rv = tv.rowView(atRow: row, makeIfNecessary: false) as? CommanderRowView {
                    configureRowView(rv, forRow: row)
                }
            }
        }

        // MARK: - NSTableViewDataSource & Delegate

        public func numberOfRows(in tableView: NSTableView) -> Int {
            cachedItems.count
        }

        public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let id = NSUserInterfaceItemIdentifier("CommanderRowView")
            let rv: CommanderRowView
            if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? CommanderRowView {
                rv = reused
            } else {
                rv = CommanderRowView()
                rv.identifier = id
            }
            configureRowView(rv, forRow: row)
            return rv
        }

        private func configureRowView(_ rv: CommanderRowView, forRow row: Int) {
            guard row >= 0 && row < cachedItems.count else { return }
            let item = cachedItems[row]
            let palette = viewModel.themePalette
            let isActive = (viewModel.activeSide == panel.side)
            let isFocused = isActive && (row == panel.cursorIndex)
            let isInactiveCursor = !isActive && (row == panel.cursorIndex)
            let isSelected = panel.selectedItemIDs.contains(item.id)

            if isFocused {
                rv.fillColor = palette.cursorBackground.nsColor
                rv.borderColor = palette.cursorBorder.nsColor
                rv.borderWidth = 1.4
            } else if isInactiveCursor {
                rv.fillColor = palette.cursorBackground.nsColor.withAlphaComponent(0.28)
                rv.borderColor = palette.cursorBorder.nsColor.withAlphaComponent(0.4)
                rv.borderWidth = 0.8
            } else if isSelected {
                rv.fillColor = palette.selectedRowTint.nsColor
                rv.borderColor = nil
                rv.borderWidth = 0
            } else {
                rv.fillColor = (row % 2 == 0) ? palette.panelBackground.nsColor : palette.panelAlternateRow.nsColor
                rv.borderColor = nil
                rv.borderWidth = 0
            }
            rv.needsDisplay = true
        }

        public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0 && row < cachedItems.count, let colID = tableColumn?.identifier.rawValue else {
                return nil
            }
            let item = cachedItems[row]
            let palette = viewModel.themePalette
            let isActive = (viewModel.activeSide == panel.side)
            let isFocused = isActive && (row == panel.cursorIndex)
            let isSelected = panel.selectedItemIDs.contains(item.id)
            let textColor = nsTextColor(for: item, palette: palette, isSelected: isSelected, isFocused: isFocused)
            let fontSize = CGFloat(viewModel.fontSize)

            if colID == "name" {
                let cellID = NSUserInterfaceItemIdentifier("NameCell")
                let cell: CommanderNameCellView
                if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? CommanderNameCellView {
                    cell = reused
                } else {
                    cell = CommanderNameCellView()
                    cell.identifier = cellID
                }

                let symName = palette.sfSymbol(for: item)
                if let img = NSImage(systemSymbolName: symName, accessibilityDescription: nil) {
                    let cfg = NSImage.SymbolConfiguration(pointSize: fontSize - 0.5, weight: .semibold)
                    cell.iconView.image = img.withSymbolConfiguration(cfg)
                    cell.iconView.contentTintColor = nsIconColor(for: item, palette: palette, isSelected: isSelected, isFocused: isFocused)
                }

                let displayName: String
                if let rel = item.relativeDisplayPath,
                   (panel.activeTab.viewMode == .branchView || panel.activeTab.viewMode == .customColumns) {
                    displayName = rel
                } else {
                    displayName = item.isDirectory ? "[\(item.name)]" : item.stem
                }
                cell.label.stringValue = displayName
                cell.label.textColor = textColor
                cell.label.font = palette.useUniformBlackFileText
                    ? NSFont.systemFont(ofSize: fontSize, weight: .bold)
                    : NSFont.monospacedSystemFont(ofSize: fontSize, weight: (item.isDirectory || isSelected) ? .bold : .regular)
                cell.placeSubviews()
                return cell
            } else {
                let cellID = NSUserInterfaceItemIdentifier("TextCell_\(colID)")
                let cell: CommanderTextCellView
                if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? CommanderTextCellView {
                    cell = reused
                } else {
                    cell = CommanderTextCellView(alignment: colID == "size" ? .right : .left)
                    cell.identifier = cellID
                }

                switch colID {
                case "ext":
                    if panel.activeTab.viewMode == .comments {
                        cell.label.stringValue = item.combinedComment
                    } else {
                        cell.label.stringValue = item.ext
                    }
                    cell.label.font = palette.useUniformBlackFileText
                        ? NSFont.systemFont(ofSize: fontSize, weight: .bold)
                        : NSFont.monospacedSystemFont(ofSize: fontSize, weight: isSelected ? .bold : .regular)
                case "size":
                    cell.label.stringValue = item.formattedSize(format: viewModel.sizeDisplayFormat)
                    cell.label.font = palette.useUniformBlackFileText
                        ? NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
                        : NSFont.monospacedSystemFont(ofSize: fontSize, weight: isSelected ? .bold : .regular)
                case "date":
                    cell.label.stringValue = item.formattedModificationDate
                    cell.label.font = palette.useUniformBlackFileText
                        ? NSFont.monospacedDigitSystemFont(ofSize: fontSize - 0.5, weight: .medium)
                        : NSFont.monospacedSystemFont(ofSize: fontSize - 0.5, weight: .regular)
                default:
                    cell.label.stringValue = ""
                }

                cell.label.textColor = textColor
                cell.placeSubviews()
                return cell
            }
        }

        private func nsTextColor(for item: FileItem, palette: CommanderThemePalette, isSelected: Bool, isFocused: Bool) -> NSColor {
            if isSelected {
                if isFocused && palette.id == .windowsClassicNavy {
                    return NSColor(srgbRed: 1.0, green: 1.0, blue: 0.2, alpha: 1.0)
                }
                return palette.selectedItemText.nsColor
            }
            if isFocused {
                return palette.cursorText.nsColor
            }
            if palette.useUniformBlackFileText {
                return item.isHidden ? palette.hiddenText.nsColor : palette.regularFileText.nsColor
            }
            return palette.regularFileText.nsColor
        }

        private func nsIconColor(for item: FileItem, palette: CommanderThemePalette, isSelected: Bool, isFocused: Bool) -> NSColor {
            if item.isParentDirectoryEntry {
                return (isFocused && palette.id == .windowsClassicNavy) ? .white : NSColor(srgbRed: 0.15, green: 0.15, blue: 0.15, alpha: 1.0)
            }
            if item.isDirectory {
                return NSColor(srgbRed: 0.91, green: 0.66, blue: 0.0, alpha: 1.0)
            }
            switch item.category {
            case .archive:
                return NSColor(srgbRed: 0.72, green: 0.42, blue: 0.08, alpha: 1.0)
            case .executable:
                return NSColor(srgbRed: 0.0, green: 0.42, blue: 0.80, alpha: 1.0)
            case .image, .audioVideo:
                return NSColor(srgbRed: 0.12, green: 0.55, blue: 0.35, alpha: 1.0)
            default:
                return (isFocused && palette.id == .windowsClassicNavy) ? .white : NSColor(srgbRed: 0.35, green: 0.40, blue: 0.46, alpha: 1.0)
            }
        }

        // MARK: - Context Menu

        private lazy var menuTarget = FileContextMenuTarget(viewModel: viewModel, panel: panel)

        func buildContextMenu(forRow row: Int) -> NSMenu? {
            guard row >= 0 && row < cachedItems.count else { return nil }
            handleRowPress(row: row, clickCount: 1, isRightClick: true)
            menuTarget.viewModel = viewModel
            menuTarget.panel = panel
            return menuTarget.menu(for: cachedItems[row])
        }

        // MARK: - In-place rename (Shift+F6 / slow double click): edit directly on the file name

        private var renameEditor: NSTextField?
        private var renameEditorItemID: String?

        private func syncInPlaceRename() {
            guard let tv = tableView else { return }
            let wanted = panel.inlineRenameItemID
            if wanted == renameEditorItemID { return }
            renameEditor?.removeFromSuperview()
            renameEditor = nil
            renameEditorItemID = nil
            guard let id = wanted,
                  let row = cachedItems.firstIndex(where: { $0.id == id }),
                  let nameCol = tv.tableColumns.firstIndex(where: { $0.identifier.rawValue == "name" }) else { return }

            tv.scrollRowToVisible(row)
            let cellRect = tv.frameOfCell(atColumn: nameCol, row: row)
            let iconInset: CGFloat = 25
            let field = NSTextField(frame: NSRect(x: cellRect.minX + iconInset, y: cellRect.minY,
                                                  width: max(80, cellRect.width - iconInset - 2), height: cellRect.height))
            field.stringValue = panel.inlineRenameText
            field.font = NSFont.systemFont(ofSize: CGFloat(viewModel.fontSize), weight: .bold)
            field.isBordered = true
            field.isBezeled = false
            field.drawsBackground = true
            field.backgroundColor = .textBackgroundColor
            field.textColor = .textColor
            field.focusRingType = .none
            field.wantsLayer = true
            field.layer?.borderWidth = 1
            field.layer?.borderColor = NSColor.controlAccentColor.cgColor
            field.cell?.isScrollable = true
            field.cell?.wraps = false
            field.delegate = self
            tv.addSubview(field)
            renameEditor = field
            renameEditorItemID = id

            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window else { return }
                window.makeFirstResponder(field)
                // Like Total Commander: select the name without its extension
                if let editor = field.currentEditor() {
                    let name = field.stringValue as NSString
                    let ext = name.pathExtension
                    let isDir = self.cachedItems.first(where: { $0.id == id })?.isDirectory ?? false
                    let stemLength = (ext.isEmpty || isDir) ? name.length : name.length - ext.count - 1
                    editor.selectedRange = NSRange(location: 0, length: max(0, stemLength))
                }
            }
        }

        public func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField, field === renameEditor else { return }
            panel.inlineRenameText = field.stringValue
        }

        /// Clicking elsewhere commits the rename (Enter/Esc are handled by the keyboard router).
        public func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField, field === renameEditor,
                  panel.inlineRenameItemID != nil else { return }
            panel.inlineRenameText = field.stringValue
            if viewModel.activeSide != panel.side { viewModel.activeSide = panel.side }
            viewModel.commitInlineRename()
            DispatchQueue.main.async { CommanderKeyboardRouter.shared.focusKeyCaptureView() }
        }

        // MARK: - Slow double click = inline rename (Total Commander / Explorer style)

        private var slowClickRow = -1
        private var slowClickTime: TimeInterval = 0
        private var renameTimer: Timer?

        /// Called on every left mouse down, before the cursor moves.
        func noteLeftMouseDown(row: Int, clickCount: Int) {
            renameTimer?.invalidate()
            renameTimer = nil
            let now = ProcessInfo.processInfo.systemUptime
            let wasFocused = viewModel.activeSide == panel.side && panel.cursorIndex == row
            defer { slowClickRow = row; slowClickTime = now }
            guard clickCount == 1, wasFocused, row == slowClickRow,
                  row >= 0, row < cachedItems.count,
                  SlowClickRename.isSlowSecondClick(sincePrevious: now - slowClickTime) else { return }
            let itemID = cachedItems[row].id
            renameTimer = Timer.scheduledTimer(withTimeInterval: NSEvent.doubleClickInterval, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.panel.cursorItemID == itemID || self.cachedItems.indices.contains(row) else { return }
                    self.panel.beginInlineRename(itemID: itemID)
                }
            }
        }

        func cancelPendingRename() {
            renameTimer?.invalidate()
            renameTimer = nil
        }
    }
}

/// "Slow double click": a second click on the already focused item after the double-click
/// interval but within 1.5 s starts rename.
enum SlowClickRename {
    static let maxGap: TimeInterval = 1.5
    static func isSlowSecondClick(sincePrevious gap: TimeInterval) -> Bool {
        gap >= NSEvent.doubleClickInterval && gap <= maxGap
    }
}

/// Shared file context menu (list view and Thumbs view).
@MainActor
final class FileContextMenuTarget: NSObject {
    var viewModel: CommanderViewModel
    var panel: PanelController

    init(viewModel: CommanderViewModel, panel: PanelController) {
        self.viewModel = viewModel
        self.panel = panel
    }

    func menu(for item: FileItem) -> NSMenu {
        let menu = NSMenu()

        func addItem(_ title: String, action: Selector) {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
            mi.target = self
            mi.representedObject = item
            menu.addItem(mi)
        }

        addItem("Open / Enter (Return)", action: #selector(ctxOpen(_:)))
        addItem("View in Lister (F3)", action: #selector(ctxView(_:)))
        addItem("Edit (F4)", action: #selector(ctxEdit(_:)))
        menu.addItem(.separator())
        addItem("Toggle Selection / Calc Size (Space)", action: #selector(ctxSpace(_:)))
        addItem("Rename (Shift+F6)", action: #selector(ctxRename(_:)))
        addItem("Multi-Rename Tool (Cmd+M)", action: #selector(ctxMultiRename(_:)))
        menu.addItem(.separator())
        addItem("Copy (F5)", action: #selector(ctxCopy(_:)))
        addItem("Move (F6)", action: #selector(ctxMove(_:)))
        addItem("Pack to Archive... (Alt+F5)", action: #selector(ctxPack(_:)))
        if item.isArchive {
            addItem("Unpack Archive... (Alt+F9)", action: #selector(ctxUnpack(_:)))
        }
        menu.addItem(.separator())
        addItem("Properties & Hash Inspector (Alt+Enter)", action: #selector(ctxProps(_:)))
        addItem("Reveal in Finder", action: #selector(ctxReveal(_:)))
        menu.addItem(.separator())
        addItem("Move to Trash (F8)", action: #selector(ctxDelete(_:)))
        return menu
    }

    @objc private func ctxOpen(_ sender: NSMenuItem) {
        if let item = sender.representedObject as? FileItem { panel.enterItem(item) }
    }
    @objc private func ctxView(_ sender: NSMenuItem) { viewModel.triggerF3View() }
    @objc private func ctxEdit(_ sender: NSMenuItem) { viewModel.triggerF4Edit() }
    @objc private func ctxSpace(_ sender: NSMenuItem) {
        panel.toggleSelectionAtCursor(advanceCursor: false, calculateDirSizeOnSpace: true)
    }
    @objc private func ctxRename(_ sender: NSMenuItem) {
        if let item = sender.representedObject as? FileItem { panel.beginInlineRename(itemID: item.id) }
    }
    @objc private func ctxMultiRename(_ sender: NSMenuItem) { viewModel.openMultiRename() }
    @objc private func ctxCopy(_ sender: NSMenuItem) { viewModel.triggerF5Copy() }
    @objc private func ctxMove(_ sender: NSMenuItem) { viewModel.triggerF6Move() }
    @objc private func ctxPack(_ sender: NSMenuItem) { viewModel.openPackDialog() }
    @objc private func ctxUnpack(_ sender: NSMenuItem) { viewModel.openUnpackDialog() }
    @objc private func ctxProps(_ sender: NSMenuItem) { viewModel.openFilePropertiesInspector() }
    @objc private func ctxReveal(_ sender: NSMenuItem) {
        if let item = sender.representedObject as? FileItem {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.fullPath)])
        }
    }
    @objc private func ctxDelete(_ sender: NSMenuItem) { viewModel.triggerF8Delete(permanent: false) }
}

/// Shared state for right-button drag selection across the cells of one grid.
final class GridRightDragTracker {
    let cells = NSHashTable<RightClickSelectCatcher.CatcherView>.weakObjects()
    var state: Bool?
    var visited: Set<String> = []

    func cell(at windowPoint: NSPoint) -> RightClickSelectCatcher.CatcherView? {
        cells.allObjects.first { view in
            guard view.window != nil else { return false }
            return view.bounds.contains(view.convert(windowPoint, from: nil))
        }
    }

    func reset() {
        state = nil
        visited = []
    }
}

/// Total Commander "right mouse button selects" for SwiftUI grid cells (Thumbs view):
/// short right click toggles selection, holding the button opens the context menu,
/// dragging with the right button applies the first cell's new state to every cell passed.
/// Left clicks and scrolling pass through to SwiftUI.
struct RightClickSelectCatcher: NSViewRepresentable {
    var itemID: String
    var tracker: GridRightDragTracker
    var onToggle: () -> Bool?                 // toggles this item, returns its new state
    var onSetSelection: (String, Bool) -> Void
    var menuProvider: () -> NSMenu?

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        update(v)
        return v
    }

    func updateNSView(_ nsView: CatcherView, context: Context) { update(nsView) }

    private func update(_ v: CatcherView) {
        v.itemID = itemID
        v.tracker = tracker
        v.onToggle = onToggle
        v.onSetSelection = onSetSelection
        v.menuProvider = menuProvider
        tracker.cells.add(v)
    }

    final class CatcherView: NSView {
        var itemID = ""
        weak var tracker: GridRightDragTracker?
        var onToggle: (() -> Bool?)?
        var onSetSelection: ((String, Bool) -> Void)?
        var menuProvider: (() -> NSMenu?)?
        private var timer: Timer?
        private var menuShown = false
        private var dragged = false

        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
                return super.hitTest(point)
            default:
                return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            menuShown = false
            dragged = false
            tracker?.reset()
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: CommanderNSTableView.rightClickMenuDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.dragged else { return }
                    self.menuShown = true
                    if let menu = self.menuProvider?() {
                        NSMenu.popUpContextMenu(menu, with: event, for: self)
                    }
                }
            }
        }

        override func rightMouseDragged(with event: NSEvent) {
            guard !menuShown, let tracker else { return }
            guard let target = tracker.cell(at: event.locationInWindow), target.itemID != itemID || dragged else { return }
            timer?.invalidate()
            if !dragged {
                dragged = true
                tracker.state = onToggle?()
                tracker.visited = [itemID]
            }
            guard let state = tracker.state, !tracker.visited.contains(target.itemID) else { return }
            tracker.visited.insert(target.itemID)
            onSetSelection?(target.itemID, state)
        }

        override func rightMouseUp(with event: NSEvent) {
            timer?.invalidate()
            timer = nil
            if !menuShown && !dragged { _ = onToggle?() }
            dragged = false
            tracker?.reset()
        }

        override func menu(for event: NSEvent) -> NSMenu? { nil }
    }
}

// MARK: - Custom 0.0ms Mouse-Down AppKit TableView & Cell Views

/// One dragged item: what goes on the pasteboard and the icon under the mouse.
struct FileDragPayload {
    let writer: NSPasteboardWriting
    let icon: NSImage
}

public final class CommanderNSTableView: NSTableView {
    public override var needsUpdateConstraints: Bool { get { false } set { } }
    var onInstantRowPress: ((Int, Int, Bool) -> Void)?
    var contextMenuProvider: ((Int) -> NSMenu?)?

    public override var acceptsFirstResponder: Bool { false }

    var onLeftMouseDown: ((Int, Int) -> Void)?
    var onLeftMouseDragged: (() -> Void)?
    /// What to drag when the press started on `row` (the selection if the row is part of it):
    /// local files as file URLs, Dropbox items as file promises.
    var dragItemsProvider: ((Int) -> [FileDragPayload])?

    private var pressRow = -1
    private var pressPoint = NSPoint.zero
    private var fileDragStarted = false

    public override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let r = row(at: pt)
        pressRow = r
        pressPoint = pt
        fileDragStarted = false
        onLeftMouseDown?(r, event.clickCount)
        if r >= 0 {
            onInstantRowPress?(r, event.clickCount, false)
        } else {
            onInstantRowPress?(-1, 1, false)
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        onLeftMouseDragged?()
        let pt = convert(event.locationInWindow, from: nil)
        if fileDragStarted { return }
        // Pulling a file out (like Explorer / Finder): drag it to a player, the Desktop, any app.
        if pressRow >= 0, hypot(pt.x - pressPoint.x, pt.y - pressPoint.y) > 5,
           let payloads = dragItemsProvider?(pressRow), !payloads.isEmpty {
            fileDragStarted = true
            beginFileDrag(payloads, event: event)
            return
        }
        let r = row(at: pt)
        if r >= 0 {
            onInstantRowPress?(r, 1, false)
        }
    }

    private func beginFileDrag(_ payloads: [FileDragPayload], event: NSEvent) {
        let iconSize = NSSize(width: 32, height: 32)
        let items: [NSDraggingItem] = payloads.prefix(200).enumerated().map { index, payload in
            let item = NSDraggingItem(pasteboardWriter: payload.writer)
            let icon = payload.icon
            icon.size = iconSize
            let offset = CGFloat(min(index, 4)) * 4
            let origin = NSPoint(x: pressPoint.x - iconSize.width / 2 + offset,
                                 y: pressPoint.y - iconSize.height / 2 + offset)
            item.setDraggingFrame(NSRect(origin: origin, size: iconSize), contents: icon)
            return item
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    /// Other apps get a copy (or an alias with Option+Cmd), never a move of the original.
    public override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link] : [.copy]
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let pt = convert(event.locationInWindow, from: nil)
        let r = row(at: pt)
        guard r >= 0 else { return nil }
        return contextMenuProvider?(r)
    }

    // MARK: Total Commander "right mouse button selects"
    // Short right click toggles the row's selection, holding the button opens the context menu,
    // dragging with the right button applies the first row's new state to every row passed.

    var onRightClickSelect: ((Int) -> Bool?)?          // toggles row, returns its new selected state
    var onRightDragSelect: ((Int, Bool) -> Void)?      // sets row to state
    static let rightClickMenuDelay: TimeInterval = 0.45

    private var rightPressRow: Int = -1
    private var rightPressState: Bool? = nil
    private var rightLastRow: Int = -1
    private var rightMenuTimer: Timer?
    private var rightMenuShown = false

    public override func rightMouseDown(with event: NSEvent) {
        let r = row(at: convert(event.locationInWindow, from: nil))
        rightPressRow = r
        rightLastRow = r
        rightPressState = nil
        rightMenuShown = false
        rightMenuTimer?.invalidate()
        guard r >= 0 else { return }
        onInstantRowPress?(r, 1, true)
        rightMenuTimer = Timer.scheduledTimer(withTimeInterval: Self.rightClickMenuDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.rightPressRow >= 0, self.rightPressState == nil else { return }
                self.rightMenuShown = true
                if let menu = self.contextMenuProvider?(self.rightPressRow) {
                    NSMenu.popUpContextMenu(menu, with: event, for: self)
                }
            }
        }
    }

    public override func rightMouseDragged(with event: NSEvent) {
        guard rightPressRow >= 0, !rightMenuShown else { return }
        let r = row(at: convert(event.locationInWindow, from: nil))
        guard r >= 0, r != rightLastRow else { return }
        rightMenuTimer?.invalidate()
        if rightPressState == nil {
            rightPressState = onRightClickSelect?(rightPressRow)
        }
        guard let state = rightPressState else { return }
        let range = rightLastRow < r ? (rightLastRow + 1)...r : r...(rightLastRow - 1)
        for row in range { onRightDragSelect?(row, state) }
        rightLastRow = r
        onInstantRowPress?(r, 1, true)
    }

    public override func rightMouseUp(with event: NSEvent) {
        rightMenuTimer?.invalidate()
        rightMenuTimer = nil
        defer { rightPressRow = -1 }
        guard rightPressRow >= 0, !rightMenuShown else { return }
        if rightPressState == nil {
            _ = onRightClickSelect?(rightPressRow)
        }
    }
}

// MARK: - Constraint-free views
// Views inside the list never request an Auto Layout pass. AppKit would otherwise propagate the
// request up to the SwiftUI host, which then re-measures the whole window on every scroll step.

final class FrameLabel: NSTextField {
    override var needsUpdateConstraints: Bool { get { false } set { } }
    override func invalidateIntrinsicContentSize() { }
}

final class FrameImageView: NSImageView {
    override var needsUpdateConstraints: Bool { get { false } set { } }
    override func invalidateIntrinsicContentSize() { }
}

public final class CommanderRowView: NSTableRowView {
    public override var needsUpdateConstraints: Bool { get { false } set { } }
    var fillColor: NSColor = .white
    var borderColor: NSColor? = nil
    var borderWidth: CGFloat = 0

    public override func draw(_ dirtyRect: NSRect) {
        fillColor.setFill()
        bounds.fill()
        if let bc = borderColor, borderWidth > 0 {
            bc.setStroke()
            let path = NSBezierPath(rect: bounds.insetBy(dx: borderWidth * 0.5, dy: borderWidth * 0.5))
            path.lineWidth = borderWidth
            path.stroke()
        }
    }
}

/// Name cell with frame-based layout (no Auto Layout): reconfiguring cells on every cursor move
/// must not trigger a window-wide constraint pass (which also re-measures the SwiftUI host).
public final class CommanderNameCellView: NSTableCellView {
    let iconView = FrameImageView()
    let label = FrameLabel(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyDown
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        addSubview(iconView)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    public override var needsUpdateConstraints: Bool {
        get { false }
        set { }
    }

    public override func layout() {
        super.layout()
        placeSubviews()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placeSubviews()
    }

    func placeSubviews() {
        let h = bounds.height
        iconView.frame = NSRect(x: 6, y: (h - 16) / 2, width: 16, height: 16)
        let lh = ceil(label.font?.boundingRectForFont.height ?? 16)
        label.frame = NSRect(x: 27, y: (h - lh) / 2, width: max(0, bounds.width - 31), height: lh)
    }
}

/// Text cell with frame-based layout (see `CommanderNameCellView`).
public final class CommanderTextCellView: NSTableCellView {
    let label = FrameLabel(labelWithString: "")

    init(alignment: NSTextAlignment) {
        super.init(frame: .zero)
        label.alignment = alignment
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    public override var needsUpdateConstraints: Bool {
        get { false }
        set { }
    }

    public override func layout() {
        super.layout()
        placeSubviews()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placeSubviews()
    }

    func placeSubviews() {
        let lh = ceil(label.font?.boundingRectForFont.height ?? 16)
        label.frame = NSRect(x: 4, y: (bounds.height - lh) / 2, width: max(0, bounds.width - 8), height: lh)
    }
}
