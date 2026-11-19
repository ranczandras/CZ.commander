import Foundation
import Combine
import AppKit

public enum PanelSide: String, Codable, Sendable {
    case left = "left"
    case right = "right"

    public var opposite: PanelSide {
        self == .left ? .right : .left
    }
}

public enum PanelSortColumn: String, CaseIterable, Codable, Sendable {
    case name = "name"
    case ext = "ext"
    case size = "size"
    case modificationDate = "date"
    case permissions = "attr"
    case unsorted = "unsorted"

    public var title: String {
        switch self {
        case .name: return "Name"
        case .ext: return "Ext"
        case .size: return "Size"
        case .modificationDate: return "Date"
        case .permissions: return "Attr"
        case .unsorted: return "Unsorted"
        }
    }
}

public enum PanelViewMode: String, CaseIterable, Codable, Sendable {
    case full = "full"
    case brief = "brief"
    case comments = "comments"
    case thumbnails = "thumbnails"
    case customColumns = "customColumns"
    case branchView = "branchView"

    /// View modes offered in the UI (CZ.commander keeps only Full and Thumbnails).
    public static let userSelectable: [PanelViewMode] = [.full, .thumbnails]

    /// Maps legacy modes (Brief, Comments, Custom, Branch) to Full.
    public var normalizedForUI: PanelViewMode {
        PanelViewMode.userSelectable.contains(self) ? self : .full
    }

    public var title: String {
        switch self {
        case .full: return "Full"
        case .brief: return "Brief"
        case .comments: return "Comments"
        case .thumbnails: return "Thumbnails"
        case .customColumns: return "Custom Columns"
        case .branchView: return "Branch View (Cmd+B)"
        }
    }
}

public enum TabLockState: String, Codable, Sendable {
    case unlocked = "unlocked"
    case locked = "locked"
    case lockedDirChangesAllowed = "lockedDirChangesAllowed"
}

public enum PanelVFSMode: Equatable, Sendable {
    case localDirectory(path: String)
    case archive(archivePath: String, internalDirectory: String)
    case searchResults(title: String, items: [FileItem], originPath: String)
    case remote(profile: RemoteConnectionProfile, remotePath: String)
}

public struct FolderTab: Identifiable, Sendable {
    public let id: UUID
    public var customTitle: String?
    public var currentPath: String
    public var lockedBasePath: String
    public var lockState: TabLockState
    public var vfsMode: PanelVFSMode
    public var viewMode: PanelViewMode
    public var sortColumn: PanelSortColumn
    public var sortAscending: Bool
    public var selectedItemIDs: Set<String>
    public var previousSelectedItemIDs: Set<String>
    public var cursorItemID: String?
    public var cursorIndex: Int
    public var quickFilter: String
    public var historyBackStack: [String]
    public var historyForwardStack: [String]
    public var calculatedDirSizes: [String: Int64]

    public init(
        id: UUID = UUID(),
        customTitle: String? = nil,
        currentPath: String,
        lockState: TabLockState = .unlocked,
        viewMode: PanelViewMode = .full,
        sortColumn: PanelSortColumn = .name,
        sortAscending: Bool = true
    ) {
        let std = (currentPath as NSString).standardizingPath
        self.id = id
        self.customTitle = customTitle
        self.currentPath = std
        self.lockedBasePath = std
        self.lockState = lockState
        self.vfsMode = .localDirectory(path: std)
        self.viewMode = viewMode
        self.sortColumn = sortColumn
        self.sortAscending = sortAscending
        self.selectedItemIDs = []
        self.previousSelectedItemIDs = []
        self.cursorItemID = nil
        self.cursorIndex = 0
        self.quickFilter = ""
        self.historyBackStack = []
        self.historyForwardStack = []
        self.calculatedDirSizes = [:]
    }

    /// True when a "locked, but directory changes allowed" tab has left its locked folder.
    public var isAwayFromLockedBase: Bool {
        lockState == .lockedDirChangesAllowed && vfsMode != .localDirectory(path: lockedBasePath)
    }

    /// Total Commander style: `*` = locked, `!` = locked tab currently showing another folder.
    public var displayTitle: String {
        let prefix: String
        switch lockState {
        case .unlocked: prefix = ""
        case .locked: prefix = "* "
        case .lockedDirChangesAllowed: prefix = isAwayFromLockedBase ? "! " : "* "
        }
        if let custom = customTitle, !custom.isEmpty {
            return prefix + custom
        }
        if lockState != .unlocked {
            let base = lockedBasePath
            return prefix + (base == "/" ? "/" : (base as NSString).lastPathComponent)
        }
        switch vfsMode {
        case .localDirectory(let path):
            if path == "/" { return prefix + "/" }
            return prefix + (path as NSString).lastPathComponent
        case .archive(let archivePath, let internalDir):
            let archName = (archivePath as NSString).lastPathComponent
            if internalDir.isEmpty {
                return prefix + "📦 \(archName)"
            }
            return prefix + "📦 \(archName)/\((internalDir as NSString).lastPathComponent)"
        case .searchResults(let title, _, _):
            return prefix + "🔍 \(title)"
        case .remote(let profile, let remPath):
            return prefix + "🌐 \(profile.title):\(remPath)"
        }
    }
}

public struct DirectoryHotlistItem: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var sourcePath: String
    public var targetPath: String?

    public init(id: UUID = UUID(), title: String, sourcePath: String, targetPath: String? = nil) {
        self.id = id
        self.title = title
        self.sourcePath = sourcePath
        self.targetPath = targetPath
    }
}

public struct ButtonBarItem: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var iconName: String
    public var command: String
    public var parameters: String

    public init(id: UUID = UUID(), title: String, iconName: String, command: String, parameters: String = "") {
        self.id = id
        self.title = title
        self.iconName = iconName
        self.command = command
        self.parameters = parameters
    }
}

public enum TransferJobState: String, Codable, Sendable {
    case queued = "Queued"
    case running = "Running"
    case paused = "Paused"
    case completed = "Completed"
    case failed = "Failed"
}

public struct TransferJob: Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var sourcePaths: [String]
    public var destinationPath: String
    public var isMove: Bool
    public var options: FileOperationOptions
    public var state: TransferJobState
    public var progress: Double
    public var speedText: String
    public var errorMessage: String?

    public init(
        id: UUID = UUID(),
        title: String,
        sourcePaths: [String],
        destinationPath: String,
        isMove: Bool,
        options: FileOperationOptions = FileOperationOptions(),
        state: TransferJobState = .queued,
        progress: Double = 0.0,
        speedText: String = "",
        errorMessage: String? = nil
    ) {
        self.id = id
        self.title = title
        self.sourcePaths = sourcePaths
        self.destinationPath = destinationPath
        self.isMove = isMove
        self.options = options
        self.state = state
        self.progress = progress
        self.speedText = speedText
        self.errorMessage = errorMessage
    }
}

// MARK: - PanelController

@MainActor
public final class PanelController: ObservableObject {
    public let side: PanelSide
    @Published public var tabs: [FolderTab]
    @Published public var activeTabIndex: Int = 0
    @Published public var rawItems: [FileItem] = []
    @Published public var displayedItems: [FileItem] = []
    @Published public var cursorIndex: Int = 0
    @Published public var cursorItemID: String? = nil
    @Published public var scrollTargetID: String? = nil
    @Published public var selectedItemIDs: Set<String> = []
    @Published public var currentVolumeInfo: VolumeInfo?
    @Published public var errorMessage: String?
    @Published public var isQuickFilterVisible: Bool = false
    @Published public var isEditingPath: Bool = false
    @Published public var inlineRenameItemID: String? = nil
    @Published public var inlineRenameText: String = ""
    @Published public var thumbnailSize: Double = 96.0
    private var sizeCalculationTasks: [String: Task<Void, Never>] = [:]

    public var showHiddenFiles: Bool = true {
        didSet { reload() }
    }

    public var directoriesAlwaysFirst: Bool = true {
        didSet { applySortAndFilter() }
    }

    public init(side: PanelSide, initialPath: String) {
        self.side = side
        self.tabs = [FolderTab(currentPath: initialPath)]
        self.activeTabIndex = 0
        reload()
    }

    public var activeTab: FolderTab {
        get {
            let safeIdx = min(max(0, activeTabIndex), max(0, tabs.count - 1))
            return tabs[safeIdx]
        }
        set {
            let safeIdx = min(max(0, activeTabIndex), max(0, tabs.count - 1))
            if tabs.indices.contains(safeIdx) {
                tabs[safeIdx] = newValue
            }
        }
    }

    public var currentPath: String {
        activeTab.currentPath
    }

    public func setCursor(to newIndex: Int, scrollIntoView: Bool = false) {
        guard !displayedItems.isEmpty else {
            if cursorIndex != 0 { cursorIndex = 0 }
            cursorItemID = nil
            return
        }
        let clamped = min(max(0, newIndex), displayedItems.count - 1)
        let newID = displayedItems[clamped].id
        if cursorIndex != clamped {
            cursorIndex = clamped
        }
        if cursorItemID != newID {
            cursorItemID = newID
        }
        if scrollIntoView && scrollTargetID != newID {
            scrollTargetID = newID
        }
    }

    public func moveCursor(by delta: Int) {
        setCursor(to: cursorIndex + delta, scrollIntoView: true)
    }

    public var focusedItem: FileItem? {
        guard displayedItems.indices.contains(cursorIndex) else {
            return displayedItems.first
        }
        return displayedItems[cursorIndex]
    }

    /// Returns all explicitly selected items, OR if none are selected, returns the currently focused item (or first real item if on `..`)
    public var actionableItems: [FileItem] {
        let selected = displayedItems.filter {
            !$0.isParentDirectoryEntry && selectedItemIDs.contains($0.id)
        }
        if !selected.isEmpty {
            return selected
        }
        if let focused = focusedItem, !focused.isParentDirectoryEntry {
            return [focused]
        }
        if let firstRealIdx = displayedItems.firstIndex(where: { !$0.isParentDirectoryEntry }) {
            setCursor(to: firstRealIdx)
            return [displayedItems[firstRealIdx]]
        }
        return []
    }

    public var selectedItemsOnly: [FileItem] {
        displayedItems.filter { !$0.isParentDirectoryEntry && selectedItemIDs.contains($0.id) }
    }

    // MARK: - Reload & Sorting

    public func reload(selectingItemNamed targetName: String? = nil) {
        errorMessage = nil
        let previousCursorID = cursorItemID
        let previousCursorIndex = cursorIndex
        selectedItemIDs = activeTab.selectedItemIDs

        do {
            switch activeTab.vfsMode {
            case .localDirectory(let path):
                if currentVolumeInfo == nil || !path.hasPrefix(currentVolumeInfo?.path ?? "//none//") {
                    currentVolumeInfo = VolumeScanner.volumeInfo(forPath: path)
                }
                if activeTab.viewMode == .branchView {
                    rawItems = FileSystemEngine.listBranchView(at: path, showHidden: showHiddenFiles)
                } else {
                    rawItems = try FileSystemEngine.listDirectory(at: path, showHidden: showHiddenFiles, includeParentEntry: true)
                }
            case .archive(let archivePath, let internalDir):
                currentVolumeInfo = VolumeScanner.volumeInfo(forPath: (archivePath as NSString).deletingLastPathComponent)
                rawItems = try ArchiveEngine.listArchiveDirectory(archivePath: archivePath, internalDirectory: internalDir)
            case .searchResults(_, let items, let originPath):
                currentVolumeInfo = VolumeScanner.volumeInfo(forPath: originPath)
                var withParent = [FileItem.parentEntry(for: originPath)]
                withParent.append(contentsOf: items)
                rawItems = withParent
            case .remote(let profile, let remPath):
                rawItems = try RemoteConnectionEngine.listDirectory(profile: profile, remotePath: remPath)
            }
        } catch {
            errorMessage = error.localizedDescription
            let parent = (activeTab.currentPath as NSString).deletingLastPathComponent
            rawItems = [FileItem.parentEntry(for: parent.isEmpty ? "/" : parent)]
        }

        let sizeCache = activeTab.calculatedDirSizes
        if !sizeCache.isEmpty {
            rawItems = rawItems.map { item in
                if item.isDirectory, let cached = sizeCache[item.fullPath] {
                    var copy = item
                    copy.calculatedDirectorySize = cached
                    return copy
                }
                return item
            }
        }

        applySortAndFilter(
            preferredSelectName: targetName,
            fallbackCursorID: previousCursorID,
            fallbackCursorIndex: previousCursorIndex
        )
    }

    public func applySortAndFilter(
        preferredSelectName: String? = nil,
        fallbackCursorID: String? = nil,
        fallbackCursorIndex: Int? = nil
    ) {
        let parentEntries = rawItems.filter { $0.isParentDirectoryEntry }
        var regularEntries = rawItems.filter { !$0.isParentDirectoryEntry }

        let filterText = activeTab.quickFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        if !filterText.isEmpty {
            if filterText.contains("*") || filterText.contains("?") {
                let matcher = WildcardMaskMatcher(expression: filterText)
                regularEntries = regularEntries.filter { matcher.matches($0.name) }
            } else {
                regularEntries = regularEntries.filter {
                    $0.name.localizedCaseInsensitiveContains(filterText)
                        || ($0.relativeDisplayPath?.localizedCaseInsensitiveContains(filterText) ?? false)
                }
            }
        }

        let col = activeTab.sortColumn
        let asc = activeTab.sortAscending
        let dirsFirst = directoriesAlwaysFirst && activeTab.viewMode != .branchView

        if col != .unsorted {
            regularEntries.sort { a, b in
                if dirsFirst && a.isDirectory != b.isDirectory {
                    return a.isDirectory && !b.isDirectory
                }
                let cmp: ComparisonResult
                switch col {
                case .name:
                    cmp = a.name.localizedStandardCompare(b.name)
                case .ext:
                    let extCmp = a.ext.localizedStandardCompare(b.ext)
                    cmp = (extCmp == .orderedSame) ? a.name.localizedStandardCompare(b.name) : extCmp
                case .size:
                    let sa = a.effectiveSize
                    let sb = b.effectiveSize
                    if sa == sb {
                        cmp = a.name.localizedStandardCompare(b.name)
                    } else {
                        cmp = (sa < sb) ? .orderedAscending : .orderedDescending
                    }
                case .modificationDate:
                    if a.modificationDate == b.modificationDate {
                        cmp = a.name.localizedStandardCompare(b.name)
                    } else {
                        cmp = (a.modificationDate < b.modificationDate) ? .orderedAscending : .orderedDescending
                    }
                case .permissions:
                    let pCmp = a.permissionsString.compare(b.permissionsString)
                    cmp = (pCmp == .orderedSame) ? a.name.localizedStandardCompare(b.name) : pCmp
                case .unsorted:
                    cmp = .orderedSame
                }
                return asc ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
            }
        }

        displayedItems = parentEntries + regularEntries

        if let nameToSelect = preferredSelectName,
           let idx = displayedItems.firstIndex(where: { $0.name == nameToSelect }) {
            setCursor(to: idx)
        } else if let prevID = fallbackCursorID ?? cursorItemID,
                  let idx = displayedItems.firstIndex(where: { $0.id == prevID }) {
            setCursor(to: idx)
        } else if let prevIdx = fallbackCursorIndex, prevIdx > 0 {
            setCursor(to: prevIdx)
        } else {
            setCursor(to: 0)
        }
    }

    public func toggleSort(by column: PanelSortColumn) {
        if activeTab.sortColumn == column {
            activeTab.sortAscending.toggle()
        } else {
            activeTab.sortColumn = column
            activeTab.sortAscending = (column == .name || column == .ext || column == .permissions)
        }
        applySortAndFilter()
    }

    // MARK: - Navigation (Enter, Backspace, History, Tabs)

    public func navigateTo(
        path: String,
        recordHistory: Bool = true,
        selectingChildNamed childName: String? = nil
    ) {
        let stdPath = (path as NSString).standardizingPath
        guard FileManager.default.fileExists(atPath: stdPath) else { return }

        if activeTab.lockState == .locked && stdPath != activeTab.lockedBasePath {
            addNewTab(atPath: stdPath)
            return
        }

        if recordHistory && activeTab.currentPath != stdPath {
            activeTab.historyBackStack.append(activeTab.currentPath)
            activeTab.historyForwardStack.removeAll()
        }

        activeTab.currentPath = stdPath
        activeTab.vfsMode = .localDirectory(path: stdPath)
        clearSelection()
        activeTab.quickFilter = ""
        isQuickFilterVisible = false
        isEditingPath = false
        cursorItemID = nil
        cursorIndex = 0
        reload(selectingItemNamed: childName)
    }

    public func enterFocusedItem() {
        guard let item = focusedItem else { return }
        enterItem(item)
    }

    public func enterItem(_ item: FileItem) {
        if item.isParentDirectoryEntry {
            goUp()
            return
        }

        switch activeTab.vfsMode {
        case .localDirectory:
            if item.isDirectory {
                if activeTab.viewMode == .branchView {
                    activeTab.viewMode = .full
                }
                navigateTo(path: item.fullPath)
            } else if item.isArchive {
                activeTab.vfsMode = .archive(archivePath: item.fullPath, internalDirectory: "")
                clearSelection()
                cursorItemID = nil
                cursorIndex = 0
                reload()
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: item.fullPath))
            }

        case .archive(let archPath, _):
            if item.isDirectory, let internalSub = item.archiveInternalPath {
                activeTab.vfsMode = .archive(archivePath: archPath, internalDirectory: internalSub)
                clearSelection()
                cursorItemID = nil
                cursorIndex = 0
                reload()
            } else if let internalFile = item.archiveInternalPath,
                      let tempPath = try? ArchiveEngine.extractEntryToTemporaryFile(archivePath: archPath, internalPath: internalFile) {
                NSWorkspace.shared.open(URL(fileURLWithPath: tempPath))
            }

        case .searchResults:
            if item.isDirectory {
                activeTab.vfsMode = .localDirectory(path: item.fullPath)
                navigateTo(path: item.fullPath)
            } else {
                let parentDir = (item.fullPath as NSString).deletingLastPathComponent
                activeTab.vfsMode = .localDirectory(path: parentDir)
                navigateTo(path: parentDir, selectingChildNamed: item.name)
            }

        case .remote(let profile, _):
            if item.isDirectory {
                activeTab.vfsMode = .remote(profile: profile, remotePath: item.fullPath)
                clearSelection()
                cursorItemID = nil
                cursorIndex = 0
                reload()
            }
        }
    }

    public func goUp() {
        switch activeTab.vfsMode {
        case .localDirectory(let path):
            guard path != "/" else { return }
            let exitedFolderName = (path as NSString).lastPathComponent
            let parentPath = (path as NSString).deletingLastPathComponent
            navigateTo(
                path: parentPath.isEmpty ? "/" : parentPath,
                selectingChildNamed: exitedFolderName
            )

        case .archive(let archivePath, let internalDir):
            let clean = internalDir.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if clean.isEmpty {
                let archiveFileName = (archivePath as NSString).lastPathComponent
                let hostDir = (archivePath as NSString).deletingLastPathComponent
                activeTab.vfsMode = .localDirectory(path: hostDir)
                activeTab.currentPath = hostDir
                clearSelection()
                reload(selectingItemNamed: archiveFileName)
            } else {
                let exitedSubName = (clean as NSString).lastPathComponent
                let parentInternal = (clean as NSString).deletingLastPathComponent
                activeTab.vfsMode = .archive(
                    archivePath: archivePath,
                    internalDirectory: parentInternal == "." ? "" : parentInternal
                )
                clearSelection()
                reload(selectingItemNamed: exitedSubName)
            }

        case .searchResults(_, _, let originPath):
            activeTab.vfsMode = .localDirectory(path: originPath)
            navigateTo(path: originPath)

        case .remote(let profile, let remPath):
            let parent = (remPath as NSString).deletingLastPathComponent
            activeTab.vfsMode = .remote(profile: profile, remotePath: parent.isEmpty ? "/" : parent)
            reload()
        }
    }

    public func goToRoot() {
        if activeTab.lockState != .unlocked {
            navigateTo(path: activeTab.lockedBasePath)
        } else {
            navigateTo(path: "/")
        }
    }

    public func goHome() {
        navigateTo(path: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    public func goBack() {
        guard let prev = activeTab.historyBackStack.popLast() else { return }
        activeTab.historyForwardStack.append(activeTab.currentPath)
        activeTab.currentPath = prev
        activeTab.vfsMode = .localDirectory(path: prev)
        reload()
    }

    public func goForward() {
        guard let next = activeTab.historyForwardStack.popLast() else { return }
        activeTab.historyBackStack.append(activeTab.currentPath)
        activeTab.currentPath = next
        activeTab.vfsMode = .localDirectory(path: next)
        reload()
    }

    // MARK: - Selection Engine (Space, Insert, +, -, *, /, Cmd+A)

    private func syncSelectionToTab() {
        activeTab.selectedItemIDs = selectedItemIDs
    }

    public func clearSelection() {
        selectedItemIDs.removeAll()
        activeTab.selectedItemIDs.removeAll()
    }

    /// Starts inline rename (Shift+F6 bar) for a specific item, e.g. after a slow double click.
    public func beginInlineRename(itemID: String) {
        guard let item = displayedItems.first(where: { $0.id == itemID }), !item.isParentDirectoryEntry else { return }
        inlineRenameItemID = item.id
        inlineRenameText = item.name
    }

    /// Sets the selection state of one item (used by right-click / right-drag selection).
    public func setSelection(ofItemID id: String, selected: Bool) {
        guard let item = displayedItems.first(where: { $0.id == id }), !item.isParentDirectoryEntry else { return }
        if selected { selectedItemIDs.insert(item.id) } else { selectedItemIDs.remove(item.id) }
        syncSelectionToTab()
    }

    public func toggleSelectionAtCursor(advanceCursor: Bool, calculateDirSizeOnSpace: Bool) {
        guard let item = focusedItem else { return }
        if !item.isParentDirectoryEntry {
            savePreviousSelectionSnapshot()
            if selectedItemIDs.contains(item.id) {
                selectedItemIDs.remove(item.id)
            } else {
                selectedItemIDs.insert(item.id)
            }
            syncSelectionToTab()

            if calculateDirSizeOnSpace && item.isDirectory && item.archiveContainerPath == nil {
                startAsyncDirectorySizeCalculation(for: item)
            }
        }

        if advanceCursor && cursorIndex + 1 < displayedItems.count {
            moveCursor(by: 1)
        }
    }

    public func startAsyncDirectorySizeCalculation(for item: FileItem) {
        let folderPath = item.fullPath
        let itemID = item.id

        sizeCalculationTasks[folderPath]?.cancel()

        if let dispIdx = displayedItems.firstIndex(where: { $0.id == itemID }) {
            displayedItems[dispIdx].isCalculatingSize = true
        }
        if let rawIdx = rawItems.firstIndex(where: { $0.id == itemID }) {
            rawItems[rawIdx].isCalculatingSize = true
        }

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let finalBytes = FileSystemEngine.calculateDirectorySize(at: folderPath) { partialBytes in
                if Task.isCancelled { return false }
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    if let dIdx = self.displayedItems.firstIndex(where: { $0.id == itemID }) {
                        self.displayedItems[dIdx].calculatedDirectorySize = partialBytes
                    }
                }
                return !Task.isCancelled
            }

            if Task.isCancelled { return }

            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.sizeCalculationTasks.removeValue(forKey: folderPath)
                self.activeTab.calculatedDirSizes[folderPath] = finalBytes
                if let rIdx = self.rawItems.firstIndex(where: { $0.id == itemID }) {
                    self.rawItems[rIdx].isCalculatingSize = false
                    self.rawItems[rIdx].calculatedDirectorySize = finalBytes
                }
                if let dIdx = self.displayedItems.firstIndex(where: { $0.id == itemID }) {
                    self.displayedItems[dIdx].isCalculatingSize = false
                    self.displayedItems[dIdx].calculatedDirectorySize = finalBytes
                }
                if self.activeTab.sortColumn == .size {
                    self.applySortAndFilter()
                }
            }
        }

        sizeCalculationTasks[folderPath] = task
    }

    public func cancelAllSizeCalculations() {
        guard !sizeCalculationTasks.isEmpty else { return }
        for (_, task) in sizeCalculationTasks {
            task.cancel()
        }
        sizeCalculationTasks.removeAll()
        for i in displayedItems.indices where displayedItems[i].isCalculatingSize {
            displayedItems[i].isCalculatingSize = false
        }
        for i in rawItems.indices where rawItems[i].isCalculatingSize {
            rawItems[i].isCalculatingSize = false
        }
    }

    public func calculateAllDirectorySizes() {
        let dirItems = displayedItems.filter {
            $0.isDirectory && !$0.isParentDirectoryEntry && $0.archiveContainerPath == nil
        }
        for dirItem in dirItems {
            startAsyncDirectorySizeCalculation(for: dirItem)
        }
    }

    public func selectGroup(pattern: String, includeDirectories: Bool = false) {
        savePreviousSelectionSnapshot()
        let matcher = WildcardMaskMatcher(expression: pattern)
        for item in displayedItems where !item.isParentDirectoryEntry {
            if !includeDirectories && item.isDirectory { continue }
            if matcher.matches(item.name) {
                selectedItemIDs.insert(item.id)
            }
        }
        syncSelectionToTab()
    }

    public func unselectGroup(pattern: String, includeDirectories: Bool = true) {
        savePreviousSelectionSnapshot()
        let matcher = WildcardMaskMatcher(expression: pattern)
        for item in displayedItems where !item.isParentDirectoryEntry {
            if !includeDirectories && item.isDirectory { continue }
            if matcher.matches(item.name) {
                selectedItemIDs.remove(item.id)
            }
        }
        syncSelectionToTab()
    }

    public func invertSelection(includeDirectories: Bool = false) {
        savePreviousSelectionSnapshot()
        for item in displayedItems where !item.isParentDirectoryEntry {
            if !includeDirectories && item.isDirectory { continue }
            if selectedItemIDs.contains(item.id) {
                selectedItemIDs.remove(item.id)
            } else {
                selectedItemIDs.insert(item.id)
            }
        }
        syncSelectionToTab()
    }

    public func restoreSelection() {
        let prev = activeTab.previousSelectedItemIDs
        guard !prev.isEmpty else { return }
        selectedItemIDs = prev
        syncSelectionToTab()
    }

    public func selectAll(includeDirectories: Bool = true) {
        savePreviousSelectionSnapshot()
        for item in displayedItems where !item.isParentDirectoryEntry {
            if !includeDirectories && item.isDirectory { continue }
            selectedItemIDs.insert(item.id)
        }
        syncSelectionToTab()
    }

    public func deselectAll() {
        savePreviousSelectionSnapshot()
        clearSelection()
    }

    public func selectSameExtension() {
        guard let item = focusedItem, !item.isParentDirectoryEntry else { return }
        savePreviousSelectionSnapshot()
        let targetExt = item.ext.lowercased()
        for entry in displayedItems where !entry.isParentDirectoryEntry && !entry.isDirectory {
            if entry.ext.lowercased() == targetExt {
                selectedItemIDs.insert(entry.id)
            }
        }
        syncSelectionToTab()
    }

    private func savePreviousSelectionSnapshot() {
        if !selectedItemIDs.isEmpty {
            activeTab.previousSelectedItemIDs = selectedItemIDs
        }
    }

    // MARK: - Tabs Management (Cmd+T, Cmd+W, Lock, Duplicate)

    public func addNewTab(atPath path: String? = nil) {
        let target = path ?? activeTab.currentPath
        let newTab = FolderTab(
            currentPath: target,
            viewMode: activeTab.viewMode,
            sortColumn: activeTab.sortColumn,
            sortAscending: activeTab.sortAscending
        )
        tabs.append(newTab)
        activeTabIndex = tabs.count - 1
        cursorIndex = 0
        cursorItemID = nil
        selectedItemIDs = []
        reload()
    }

    public func duplicateActiveTab() {
        let copy = FolderTab(
            customTitle: activeTab.customTitle,
            currentPath: activeTab.currentPath,
            lockState: .unlocked,
            viewMode: activeTab.viewMode,
            sortColumn: activeTab.sortColumn,
            sortAscending: activeTab.sortAscending
        )
        tabs.insert(copy, at: activeTabIndex + 1)
        activeTabIndex += 1
        cursorIndex = 0
        cursorItemID = nil
        selectedItemIDs = []
        reload()
    }

    /// Closes a tab. Locked tabs are only closed when `force` is true (explicit menu action).
    public func closeTab(at index: Int? = nil, force: Bool = false) {
        let idx = index ?? activeTabIndex
        guard tabs.count > 1 && tabs.indices.contains(idx) else { return }
        if tabs[idx].lockState != .unlocked && !force { return }
        removeTabs(at: [idx])
    }

    /// Closes every other tab except locked ones (Total Commander: locked tabs survive "close all").
    public func closeOtherTabs(keeping index: Int) {
        guard tabs.indices.contains(index) else { return }
        let doomed = tabs.indices.filter { $0 != index && tabs[$0].lockState == .unlocked }
        removeTabs(at: doomed, preferActiveID: tabs[index].id)
    }

    public func closeAllUnlockedTabs() {
        let doomed = tabs.indices.filter { tabs[$0].lockState == .unlocked && $0 != activeTabIndex }
        removeTabs(at: doomed, preferActiveID: activeTab.id)
    }

    /// Closes unlocked tabs that show the same folder as an earlier tab.
    public func closeDuplicateTabs() {
        func key(_ tab: FolderTab) -> String { tab.lockState == .unlocked ? tab.currentPath : tab.lockedBasePath }
        // The active tab and locked tabs always stay; other unlocked tabs showing an already kept folder go.
        var seen = Set<String>([key(activeTab)])
        for tab in tabs where tab.lockState != .unlocked { seen.insert(key(tab)) }
        var doomed: [Int] = []
        for (i, tab) in tabs.enumerated() where i != activeTabIndex && tab.lockState == .unlocked {
            if seen.contains(key(tab)) { doomed.append(i) } else { seen.insert(key(tab)) }
        }
        removeTabs(at: doomed, preferActiveID: activeTab.id)
    }

    private func removeTabs(at indices: [Int], preferActiveID: UUID? = nil) {
        guard !indices.isEmpty else { return }
        let activeID = preferActiveID ?? activeTab.id
        let doomed = Set(indices)
        let oldActive = activeTabIndex
        tabs = tabs.enumerated().filter { !doomed.contains($0.offset) }.map { $0.element }
        if tabs.isEmpty { return }
        if let keep = tabs.firstIndex(where: { $0.id == activeID }) {
            activeTabIndex = keep
        } else {
            activeTabIndex = min(max(0, oldActive - doomed.filter { $0 < oldActive }.count), tabs.count - 1)
        }
        cursorIndex = activeTab.cursorIndex
        cursorItemID = activeTab.cursorItemID
        selectedItemIDs = activeTab.selectedItemIDs
        reload()
    }

    /// Sets the lock mode. Locking an unlocked tab pins its current folder as the locked folder.
    public func setTabLock(at index: Int, to state: TabLockState) {
        guard tabs.indices.contains(index) else { return }
        if tabs[index].lockState == .unlocked && state != .unlocked {
            tabs[index].lockedBasePath = tabs[index].currentPath
        }
        tabs[index].lockState = state
        objectWillChange.send()
    }

    /// Makes the tab's current folder its new locked folder.
    public func relockTabAtCurrentFolder(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].lockedBasePath = tabs[index].currentPath
        objectWillChange.send()
    }

    public func renameTab(at index: Int, to title: String) {
        guard tabs.indices.contains(index) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        tabs[index].customTitle = trimmed.isEmpty ? nil : trimmed
        objectWillChange.send()
    }

    public func cycleTabLock(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        switch tabs[index].lockState {
        case .unlocked: setTabLock(at: index, to: .locked)
        case .locked: setTabLock(at: index, to: .lockedDirChangesAllowed)
        case .lockedDirChangesAllowed: setTabLock(at: index, to: .unlocked)
        }
    }

    /// Activates a tab. A "locked, but directory changes allowed" tab jumps back to its
    /// locked folder when it is selected again (also when its already-active tab is clicked).
    public func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let switching = index != activeTabIndex
        if switching {
            activeTabIndex = index
            cursorIndex = activeTab.cursorIndex
            cursorItemID = activeTab.cursorItemID
            selectedItemIDs = activeTab.selectedItemIDs
        }
        if returnLockedTabToBase() { return }
        if switching { reload() }
    }

    /// Sends the active "locked, dir changes allowed" tab back to its locked folder. Returns true if it moved.
    @discardableResult
    public func returnLockedTabToBase() -> Bool {
        guard activeTab.isAwayFromLockedBase else { return false }
        let base = activeTab.lockedBasePath
        guard FileManager.default.fileExists(atPath: base) else { return false }
        navigateTo(path: base)
        return true
    }

    public func selectNextTab() {
        guard tabs.count > 1 else { return }
        selectTab(at: (activeTabIndex + 1) % tabs.count)
    }

    public func selectPreviousTab() {
        guard tabs.count > 1 else { return }
        selectTab(at: (activeTabIndex - 1 + tabs.count) % tabs.count)
    }

    public func feedSearchResults(_ items: [FileItem], title: String) {
        let origin = activeTab.currentPath
        activeTab.vfsMode = .searchResults(title: title, items: items, originPath: origin)
        clearSelection()
        cursorIndex = 0
        cursorItemID = nil
        reload()
    }

    public func statusBarText(format: FileSizeDisplayFormat) -> String {
        let nonParent = displayedItems.filter { !$0.isParentDirectoryEntry }
        let files = nonParent.filter { !$0.isDirectory }
        let dirs = nonParent.filter { $0.isDirectory }

        let selectedFiles = files.filter { selectedItemIDs.contains($0.id) }
        let selectedDirs = dirs.filter { selectedItemIDs.contains($0.id) }

        let totalBytes = nonParent.reduce(Int64(0)) { $0 + $1.effectiveSize }
        let selectedBytes = nonParent
            .filter { selectedItemIDs.contains($0.id) }
            .reduce(Int64(0)) { $0 + $1.effectiveSize }

        return L10n.statusSummary(
            selectedBytes: selectedBytes,
            totalBytes: totalBytes,
            selectedFiles: selectedFiles.count,
            totalFiles: files.count,
            selectedDirs: selectedDirs.count,
            totalDirs: dirs.count,
            format: format
        )
    }
}

// MARK: - Active Sheet / Dialog Enumeration

public enum ActiveCommanderSheet: Identifiable {
    case lister(filePath: String, initialMode: ListerMode)
    case editor(filePath: String, isNewFile: Bool)
    case copyDialog(sources: [FileItem], destinationDir: String, isMove: Bool)
    case mkdirDialog(baseDir: String)
    case packDialog(sources: [FileItem], destinationDir: String)
    case unpackDialog(archives: [FileItem], destinationDir: String)
    case multiRename(items: [FileItem])
    case findFiles(initialPath: String)
    case syncDirectories(leftPath: String, rightPath: String)
    case compareByContent(leftPath: String, rightPath: String)
    case checksumCreate(files: [FileItem])
    case checksumVerify(manifestPath: String)
    case splitFile(file: FileItem, destinationDir: String)
    case combineFiles(partOrCRC: FileItem, destinationDir: String)
    case encodeFile(file: FileItem, destinationDir: String)
    case decodeFile(file: FileItem, destinationDir: String)
    case changeAttributes(items: [FileItem])
    case remoteConnections
    case diskSpaceAnalyzer(path: String)
    case backgroundTransferManager
    case selectGroupDialog(isSelect: Bool)
    case fileProperties(item: FileItem)
    case exportFileList(items: [FileItem], directoryPath: String)
    case buttonBarEditor
    case fullDiskAccess
    case settings
    case deleteConfirm(items: [FileItem], permanent: Bool, secureWipe: Bool)
    case renameTab(side: PanelSide, index: Int)

    public var id: String {
        switch self {
        case .renameTab(let side, let index): return "renametab:\(side):\(index)"
        case .deleteConfirm(_, let permanent, _): return "deleteconfirm:\(permanent)"
        case .lister(let p, let m): return "lister:\(p):\(m.rawValue)"
        case .editor(let p, _): return "editor:\(p)"
        case .copyDialog(_, _, let m): return "copy:\(m)"
        case .mkdirDialog(let b): return "mkdir:\(b)"
        case .packDialog: return "pack"
        case .unpackDialog: return "unpack"
        case .multiRename: return "multirename"
        case .findFiles: return "findfiles"
        case .syncDirectories: return "syncdirs"
        case .compareByContent: return "comparecontent"
        case .checksumCreate: return "checksumcreate"
        case .checksumVerify(let p): return "checksumverify:\(p)"
        case .splitFile: return "split"
        case .combineFiles: return "combine"
        case .encodeFile: return "encode"
        case .decodeFile: return "decode"
        case .changeAttributes: return "changeattr"
        case .remoteConnections: return "remote"
        case .diskSpaceAnalyzer(let p): return "diskspace:\(p)"
        case .backgroundTransferManager: return "bgm"
        case .selectGroupDialog(let s): return "selgroup:\(s)"
        case .fileProperties(let item): return "props:\(item.id)"
        case .exportFileList: return "exportlist"
        case .buttonBarEditor: return "buttonbareditor"
        case .fullDiskAccess: return "fulldiskaccess"
        case .settings: return "settings"
        }
    }
}

// MARK: - Master CommanderViewModel

@MainActor
public final class CommanderViewModel: ObservableObject {
    public static let shared = CommanderViewModel()

    @Published public var leftPanel: PanelController
    @Published public var rightPanel: PanelController
    @Published public var activeSide: PanelSide = .left

    // UI / Layout Toggles
    @Published public var isHorizontalSplit: Bool = false
    @Published public var isQuickViewActive: Bool = false // Cmd+Y
    @Published public var showDirectoryTreeSidebar: Bool = false // Cmd+F8
    @Published public var showButtonBar: Bool = true
    @Published public var showDriveBar: Bool = true
    @Published public var showFunctionKeyBar: Bool = true
    @Published public var showHiddenFiles: Bool = true {
        didSet {
            leftPanel.showHiddenFiles = showHiddenFiles
            rightPanel.showHiddenFiles = showHiddenFiles
        }
    }

    // Theme & Localization
    @Published public var themeID: CommanderThemeID = .windowsDefault
    @Published public var sizeDisplayFormat: FileSizeDisplayFormat = .dynamicKMG
    @Published public var fontSize: Double = 12.5

    // Active Modal / Tool
    @Published public var activeSheet: ActiveCommanderSheet? = nil
    @Published public var statusBannerMessage: String? = nil

    // Bookmarks, Remote Profiles, Button Bar, Transfer Queue
    @Published public var hotlist: [DirectoryHotlistItem] = []
    @Published public var remoteProfiles: [RemoteConnectionProfile] = []
    @Published public var buttonBarItems: [ButtonBarItem] = []
    @Published public var multiRenamePresets: [MultiRenamePreset] = MultiRenamePreset.builtInPresets
    @Published public var transferQueue: [TransferJob] = []
    @Published public var mountedVolumes: [VolumeInfo] = []
    @Published public var quickShortcuts: [VolumeInfo] = []

    private var cancellables: Set<AnyCancellable> = []

    public init(
        leftInitialPath: String? = nil,
        rightInitialPath: String? = nil
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let defaultLeft = leftInitialPath ?? home
        let defaultRight = rightInitialPath ?? "/Applications"

        let lPanel = PanelController(side: .left, initialPath: defaultLeft)
        let rPanel = PanelController(side: .right, initialPath: defaultRight)
        self.leftPanel = lPanel
        self.rightPanel = rPanel

        self.mountedVolumes = VolumeScanner.mountedVolumes()
        self.quickShortcuts = VolumeScanner.quickShortcuts()

        self.hotlist = [
            DirectoryHotlistItem(title: "🏠 Home (~)", sourcePath: home),
            DirectoryHotlistItem(title: "📥 Downloads", sourcePath: (home as NSString).appendingPathComponent("Downloads")),
            DirectoryHotlistItem(title: "🖥 Desktop", sourcePath: (home as NSString).appendingPathComponent("Desktop")),
            DirectoryHotlistItem(title: "📦 Applications", sourcePath: "/Applications")
        ]

        self.buttonBarItems = Self.defaultButtonBarItems

        self.remoteProfiles = []

        loadSavedConfiguration()
    }

    public static let defaultButtonBarItems: [ButtonBarItem] = [
        ButtonBarItem(title: "Reread (F2)", iconName: "arrow.clockwise", command: "cm_RereadSource"),
        ButtonBarItem(title: "View", iconName: "rectangle.grid.2x2", command: "cm_SwitchView"),
        ButtonBarItem(title: "Hidden (Cmd+H)", iconName: "h.square", command: "cm_SwitchHidSys"),
        ButtonBarItem(title: "QuickView (Cmd+Y)", iconName: "eye", command: "cm_SrcQuickview"),
        ButtonBarItem(title: "Tree (Cmd+F8)", iconName: "sidebar.left", command: "cm_SwitchSeparateTree"),
        ButtonBarItem(title: "Multi-Rename (Cmd+M)", iconName: "pencil.and.list.clipboard", command: "cm_MultiRenameFiles"),
        ButtonBarItem(title: "Find Files (Alt+F7)", iconName: "magnifyingglass", command: "cm_SearchFor"),
        ButtonBarItem(title: "Sync Dirs", iconName: "arrow.left.arrow.right.square", command: "cm_FileSync"),
        ButtonBarItem(title: "Compare Content", iconName: "doc.on.doc", command: "cm_CompareFilesByContent"),
        ButtonBarItem(title: "Pack (Alt+F5)", iconName: "archivebox", command: "cm_PackFiles"),
        ButtonBarItem(title: "Unpack (Alt+F9)", iconName: "shippingbox.and.arrow.backward", command: "cm_UnpackFiles"),
        ButtonBarItem(title: "FTP/SFTP (Cmd+Shift+F)", iconName: "network", command: "cm_FtpConnect"),
        ButtonBarItem(title: "Disk Space", iconName: "chart.pie", command: "cm_GetFileSpace"),
        ButtonBarItem(title: "Properties (Alt+Enter)", iconName: "info.circle", command: "cm_Properties")
    ]

    public var activePanel: PanelController {
        activeSide == .left ? leftPanel : rightPanel
    }

    /// Commands removed from the toolbar (view modes other than Full / Thumbnails).
    static let retiredToolbarCommands: Set<String> = ["cm_ExecuteDOS", "cm_SrcBrief", "cm_SrcFull", "cm_SrcThumbs", "cm_SrcComments", "cm_SrcCustom", "cm_DirBranch"]

    /// Migrates a saved toolbar: drops retired view-mode buttons, adds View + Hidden after Reread.
    static func migrateToolbar(_ items: [ButtonBarItem]) -> [ButtonBarItem] {
        var result = items.filter { !retiredToolbarCommands.contains($0.command) }.map { item -> ButtonBarItem in
            var item = item
            item.title = item.title
                .replacingOccurrences(of: "Ctrl+Q", with: "Cmd+Y")
                .replacingOccurrences(of: "Ctrl+F)", with: "Cmd+Shift+F)")
                .replacingOccurrences(of: "Ctrl+", with: "Cmd+")
            return item
        }
        let defaults = defaultButtonBarItems
        var insertAt = (result.firstIndex { $0.command == "cm_RereadSource" }).map { $0 + 1 } ?? 0
        for cmd in ["cm_SwitchView", "cm_SwitchHidSys"] where !result.contains(where: { $0.command == cmd }) {
            if let item = defaults.first(where: { $0.command == cmd }) {
                result.insert(item, at: min(insertAt, result.count))
                insertAt += 1
            }
        }
        return result
    }

    /// Toggles the active panel between Full and Thumbnails.
    public func switchActiveViewMode() {
        let current = activePanel.activeTab.viewMode
        activePanel.activeTab.viewMode = current == .thumbnails ? .full : .thumbnails
        activePanel.reload()
    }

    public var inactivePanel: PanelController {
        activeSide == .left ? rightPanel : leftPanel
    }

    public var themePalette: CommanderThemePalette {
        CommanderThemePalette.palette(for: themeID)
    }

    public func refreshVolumes() {
        mountedVolumes = VolumeScanner.mountedVolumes()
        quickShortcuts = VolumeScanner.quickShortcuts()
        leftPanel.reload()
        rightPanel.reload()
    }

    public func switchActivePanel() {
        activeSide = activeSide.opposite
    }

    public func swapPanels() {
        let leftTabs = leftPanel.tabs
        let leftIdx = leftPanel.activeTabIndex
        leftPanel.tabs = rightPanel.tabs
        leftPanel.activeTabIndex = rightPanel.activeTabIndex
        rightPanel.tabs = leftTabs
        rightPanel.activeTabIndex = leftIdx
        leftPanel.reload()
        rightPanel.reload()
    }

    public func makeTargetEqualSource() {
        inactivePanel.navigateTo(path: activePanel.currentPath)
    }

    // MARK: - Total Commander Internal Commands (`cm_*`)

    public func executeInternalCommand(_ command: String) {
        switch command {
        case "cm_RereadSource":
            refreshVolumes()
        case "cm_SwitchView":
            switchActiveViewMode()
        case "cm_SrcThumbs":
            activePanel.activeTab.viewMode = .thumbnails
            activePanel.reload()
        case "cm_SrcFull", "cm_SrcBrief", "cm_SrcComments", "cm_SrcCustom", "cm_DirBranch":
            // Only Full and Thumbnails exist in CZ.commander; legacy view commands fall back to Full.
            activePanel.activeTab.viewMode = .full
            activePanel.reload()
        case "cm_SrcQuickview":
            isQuickViewActive.toggle()
        case "cm_SwitchSeparateTree":
            showDirectoryTreeSidebar.toggle()
        case "cm_MultiRenameFiles":
            openMultiRename()
        case "cm_SearchFor":
            activeSheet = .findFiles(initialPath: activePanel.currentPath)
        case "cm_FileSync":
            activeSheet = .syncDirectories(leftPath: leftPanel.currentPath, rightPath: rightPanel.currentPath)
        case "cm_CompareFilesByContent":
            openCompareByContent()
        case "cm_CompareDirs":
            compareDirectoriesShiftF2()
        case "cm_PackFiles":
            openPackDialog()
        case "cm_UnpackFiles":
            openUnpackDialog()
        case "cm_FtpConnect":
            activeSheet = .remoteConnections
        case "cm_GetFileSpace":
            activeSheet = .diskSpaceAnalyzer(path: activePanel.currentPath)
        case "cm_Properties":
            openFilePropertiesInspector()
        case "cm_Exchange":
            swapPanels()
        case "cm_MatchSrc":
            makeTargetEqualSource()
        case "cm_VerticalPanels":
            isHorizontalSplit.toggle()
        case "cm_SwitchHidSys":
            showHiddenFiles.toggle()
        default:
            break
        }
    }

    // MARK: - F3 .. F8 Actions

    public func triggerF3View(initialMode: ListerMode = .text) {
        guard let item = activePanel.actionableItems.first else {
            activeSheet = .diskSpaceAnalyzer(path: activePanel.currentPath)
            return
        }
        if item.isDirectory {
            activeSheet = .diskSpaceAnalyzer(path: item.fullPath)
            return
        }
        if let archPath = item.archiveContainerPath,
           let internalPath = item.archiveInternalPath,
           let tempFile = try? ArchiveEngine.extractEntryToTemporaryFile(archivePath: archPath, internalPath: internalPath) {
            activeSheet = .lister(filePath: tempFile, initialMode: initialMode)
            return
        }
        activeSheet = .lister(filePath: item.fullPath, initialMode: initialMode)
    }

    public func triggerF4Edit(createNew: Bool = false) {
        if createNew {
            let newFilePath = (activePanel.currentPath as NSString).appendingPathComponent("new_file.txt")
            activeSheet = .editor(filePath: newFilePath, isNewFile: true)
            return
        }
        if let item = activePanel.actionableItems.first(where: { !$0.isDirectory }) {
            if let archPath = item.archiveContainerPath,
               let internalPath = item.archiveInternalPath,
               let tempFile = try? ArchiveEngine.extractEntryToTemporaryFile(archivePath: archPath, internalPath: internalPath) {
                activeSheet = .editor(filePath: tempFile, isNewFile: false)
                return
            }
            activeSheet = .editor(filePath: item.fullPath, isNewFile: false)
        } else {
            let newFilePath = (activePanel.currentPath as NSString).appendingPathComponent("new_file.txt")
            activeSheet = .editor(filePath: newFilePath, isNewFile: true)
        }
    }

    public func triggerF5Copy(inSameDirectory: Bool = false) {
        let items = activePanel.actionableItems
        guard !items.isEmpty else {
            statusBannerMessage = "No items to copy in this folder!"
            return
        }
        let dest = inSameDirectory ? activePanel.currentPath : inactivePanel.currentPath
        activeSheet = .copyDialog(sources: items, destinationDir: dest, isMove: false)
    }

    public func triggerF6Move(inlineRename: Bool = false) {
        if inlineRename {
            guard let target = activePanel.actionableItems.first else { return }
            activePanel.inlineRenameItemID = target.id
            activePanel.inlineRenameText = target.name
            return
        }
        let items = activePanel.actionableItems
        guard !items.isEmpty else {
            statusBannerMessage = "No items to move in this folder!"
            return
        }
        activeSheet = .copyDialog(sources: items, destinationDir: inactivePanel.currentPath, isMove: true)
    }

    public func commitInlineRename() {
        guard let id = activePanel.inlineRenameItemID,
              let item = activePanel.displayedItems.first(where: { $0.id == id }) else {
            activePanel.inlineRenameItemID = nil
            return
        }
        let newName = activePanel.inlineRenameText.trimmingCharacters(in: .whitespacesAndNewlines)
        activePanel.inlineRenameItemID = nil
        guard !newName.isEmpty && newName != item.name else { return }

        let dir = (item.fullPath as NSString).deletingLastPathComponent
        let newFullPath = (dir as NSString).appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(atPath: item.fullPath, toPath: newFullPath)
            activePanel.reload(selectingItemNamed: newName)
            inactivePanel.reload()
        } catch {
            statusBannerMessage = error.localizedDescription
        }
    }

    public func triggerF7NewFolder() {
        activeSheet = .mkdirDialog(baseDir: activePanel.currentPath)
    }

    /// F8 / Delete: asks for confirmation first (Total Commander style), see `performDelete`.
    public func triggerF8Delete(permanent: Bool = false, secureWipe: Bool = false) {
        let items = activePanel.actionableItems
        guard !items.isEmpty else {
            statusBannerMessage = "No item selected to delete!"
            return
        }
        activeSheet = .deleteConfirm(items: items, permanent: permanent, secureWipe: secureWipe)
    }

    /// Deletes the confirmed items (trash, permanent, or secure wipe; archive entries in archive mode).
    public func performDelete(items: [FileItem], permanent: Bool = false, secureWipe: Bool = false) {
        guard !items.isEmpty else { return }

        if case .archive(let archivePath, _) = activePanel.activeTab.vfsMode {
            let internalPaths = items.compactMap { $0.archiveInternalPath }
            do {
                try ArchiveEngine.deleteEntriesFromArchive(archivePath: archivePath, internalPaths: internalPaths)
                activePanel.reload()
                statusBannerMessage = "Deleted from archive (\(internalPaths.count))"
            } catch {
                statusBannerMessage = error.localizedDescription
            }
            return
        }

        do {
            try FileSystemEngine.deleteItems(
                atPaths: items.map { $0.fullPath },
                moveToTrash: !permanent,
                secureWipe: secureWipe
            )
            activePanel.clearSelection()
            activePanel.reload()
            inactivePanel.reload()
            statusBannerMessage = "Deleted \(items.count) item(s)"
        } catch {
            statusBannerMessage = error.localizedDescription
        }
    }

    // MARK: - Power Tool Triggers

    public func openMultiRename() {
        let selected = activePanel.selectedItemsOnly
        if !selected.isEmpty {
            activeSheet = .multiRename(items: selected)
            return
        }
        let allNonParent = activePanel.displayedItems.filter { !$0.isParentDirectoryEntry }
        guard !allNonParent.isEmpty else {
            statusBannerMessage = "Folder is empty, no items to rename!"
            return
        }
        activeSheet = .multiRename(items: allNonParent)
    }

    public func openPackDialog() {
        let items = activePanel.actionableItems
        guard !items.isEmpty else {
            statusBannerMessage = "No items to pack!"
            return
        }
        activeSheet = .packDialog(sources: items, destinationDir: inactivePanel.currentPath)
    }

    public func openUnpackDialog() {
        let archives = activePanel.actionableItems.filter { $0.isArchive }
        if !archives.isEmpty {
            activeSheet = .unpackDialog(archives: archives, destinationDir: inactivePanel.currentPath)
            return
        }
        let allArchivesInPanel = activePanel.displayedItems.filter { $0.isArchive }
        if !allArchivesInPanel.isEmpty {
            activeSheet = .unpackDialog(archives: [allArchivesInPanel[0]], destinationDir: inactivePanel.currentPath)
        } else {
            statusBannerMessage = "Select an archive file (.zip, .tar.gz, etc.) to unpack!"
        }
    }

    public func testSelectedArchives() {
        let items = activePanel.actionableItems.filter { $0.isArchive }
        guard !items.isEmpty else {
            statusBannerMessage = "No archive selected"
            return
        }
        var okCount = 0
        var totalEntries = 0
        for arch in items {
            let res = ArchiveEngine.testArchive(atPath: arch.fullPath)
            if res.isValid {
                okCount += 1
                totalEntries += res.testedEntriesCount
            }
        }
        statusBannerMessage = "Archive test complete: \(okCount)/\(items.count) OK (\(totalEntries) files)"
    }

    public func openCompareByContent() {
        let activeSel = activePanel.selectedItemsOnly.filter { !$0.isDirectory }
        if activeSel.count == 2 {
            activeSheet = .compareByContent(leftPath: activeSel[0].fullPath, rightPath: activeSel[1].fullPath)
            return
        }
        let lCandidate = leftPanel.actionableItems.first(where: { !$0.isDirectory })
        let rCandidate = rightPanel.actionableItems.first(where: { !$0.isDirectory })
        if let lItem = lCandidate, let rItem = rCandidate {
            activeSheet = .compareByContent(leftPath: lItem.fullPath, rightPath: rItem.fullPath)
        } else {
            statusBannerMessage = "Select files in Left & Right panels to compare by content!"
        }
    }

    public func compareDirectoriesShiftF2() {
        let (selL, selR) = CompareByContentEngine.comparePanelItems(
            leftItems: leftPanel.displayedItems,
            rightItems: rightPanel.displayedItems
        )
        leftPanel.selectedItemIDs = selL
        leftPanel.activeTab.selectedItemIDs = selL
        rightPanel.selectedItemIDs = selR
        rightPanel.activeTab.selectedItemIDs = selR
        statusBannerMessage = "Compare Dirs: Selected \(selL.count) in Left, \(selR.count) in Right"
    }

    public func openChecksumCreator() {
        let files = activePanel.actionableItems.filter { !$0.isDirectory }
        guard !files.isEmpty else {
            statusBannerMessage = "Select at least one file to create checksum!"
            return
        }
        activeSheet = .checksumCreate(files: files)
    }

    public func openChecksumVerifier() {
        guard let focused = activePanel.actionableItems.first(where: { !$0.isDirectory }) else { return }
        activeSheet = .checksumVerify(manifestPath: focused.fullPath)
    }

    public func openSplitFile() {
        guard let focused = activePanel.actionableItems.first(where: { !$0.isDirectory }) else {
            statusBannerMessage = "Select a file to split!"
            return
        }
        activeSheet = .splitFile(file: focused, destinationDir: inactivePanel.currentPath)
    }

    public func openCombineFiles() {
        guard let focused = activePanel.actionableItems.first(where: { !$0.isDirectory }) else {
            statusBannerMessage = "Select a .001 or .crc file to combine!"
            return
        }
        activeSheet = .combineFiles(partOrCRC: focused, destinationDir: inactivePanel.currentPath)
    }

    public func openEncodeFile() {
        guard let focused = activePanel.actionableItems.first(where: { !$0.isDirectory }) else { return }
        activeSheet = .encodeFile(file: focused, destinationDir: inactivePanel.currentPath)
    }

    public func openDecodeFile() {
        guard let focused = activePanel.actionableItems.first(where: { !$0.isDirectory }) else { return }
        activeSheet = .decodeFile(file: focused, destinationDir: inactivePanel.currentPath)
    }

    public func openChangeAttributes() {
        let items = activePanel.actionableItems
        guard !items.isEmpty else { return }
        activeSheet = .changeAttributes(items: items)
    }

    public func openFilePropertiesInspector() {
        if let item = activePanel.actionableItems.first {
            activeSheet = .fileProperties(item: item)
        } else if let currentDirItem = FileSystemEngine.inspectFileItem(atPath: activePanel.currentPath) {
            activeSheet = .fileProperties(item: currentDirItem)
        }
    }

    public func openExportFileList() {
        let items = activePanel.selectedItemsOnly.isEmpty
            ? activePanel.displayedItems.filter { !$0.isParentDirectoryEntry }
            : activePanel.selectedItemsOnly
        activeSheet = .exportFileList(items: items, directoryPath: activePanel.currentPath)
    }

    // MARK: - Background Transfer Queue

    public func enqueueTransferJob(
        sources: [String],
        destination: String,
        isMove: Bool,
        options: FileOperationOptions
    ) {
        let opLabel = isMove ? "Move" : "Copy"
        let job = TransferJob(
            title: "\(opLabel) (\(sources.count)) -> \((destination as NSString).lastPathComponent)",
            sourcePaths: sources,
            destinationPath: destination,
            isMove: isMove,
            options: options
        )
        transferQueue.append(job)
        processNextTransferJob()
    }

    public func processNextTransferJob() {
        guard let idx = transferQueue.firstIndex(where: { $0.state == .queued }) else { return }
        transferQueue[idx].state = .running
        let job = transferQueue[idx]

        do {
            _ = try FileSystemEngine.copyOrMoveItems(
                sources: job.sourcePaths,
                toDestinationDirectory: job.destinationPath,
                isMove: job.isMove,
                options: job.options
            ) { progress in
                if let i = self.transferQueue.firstIndex(where: { $0.id == job.id }) {
                    self.transferQueue[i].progress = progress.fractionCompleted
                    let mbps = progress.bytesPerSecond / 1_048_576.0
                    self.transferQueue[i].speedText = String(format: "%.1f MB/s", mbps)
                }
            }
            if let i = transferQueue.firstIndex(where: { $0.id == job.id }) {
                transferQueue[i].state = .completed
                transferQueue[i].progress = 1.0
            }
            leftPanel.reload()
            rightPanel.reload()
        } catch {
            if let i = transferQueue.firstIndex(where: { $0.id == job.id }) {
                transferQueue[i].state = .failed
                transferQueue[i].errorMessage = error.localizedDescription
            }
        }

        if transferQueue.contains(where: { $0.state == .queued }) {
            processNextTransferJob()
        }
    }

    // MARK: - Configuration Persistence

    public func saveCurrentConfiguration() {
        let leftSaved = leftPanel.tabs.map {
            SavedTabDescriptor(
                customTitle: $0.customTitle,
                path: $0.currentPath,
                lockedBasePath: $0.lockState == .unlocked ? nil : $0.lockedBasePath,
                lockState: $0.lockState,
                viewMode: $0.viewMode,
                sortColumn: $0.sortColumn,
                sortAscending: $0.sortAscending
            )
        }
        let rightSaved = rightPanel.tabs.map {
            SavedTabDescriptor(
                customTitle: $0.customTitle,
                path: $0.currentPath,
                lockedBasePath: $0.lockState == .unlocked ? nil : $0.lockedBasePath,
                lockState: $0.lockState,
                viewMode: $0.viewMode,
                sortColumn: $0.sortColumn,
                sortAscending: $0.sortAscending
            )
        }
        let cfg = CommanderSavedConfiguration(
            themeID: themeID,
            sizeDisplayFormat: sizeDisplayFormat,
            fontSize: fontSize,
            isHorizontalSplit: isHorizontalSplit,
            showHiddenFiles: showHiddenFiles,
            showButtonBar: showButtonBar,
            showDriveBar: showDriveBar,
            showCommandLine: false,
            showFunctionKeyBar: showFunctionKeyBar,
            leftTabs: leftSaved,
            leftActiveTabIndex: leftPanel.activeTabIndex,
            rightTabs: rightSaved,
            rightActiveTabIndex: rightPanel.activeTabIndex,
            hotlist: hotlist,
            remoteProfiles: remoteProfiles,
            buttonBarItems: buttonBarItems,
            multiRenamePresets: multiRenamePresets,
            commandHistory: []
        )
        try? PersistenceManager.saveConfiguration(cfg)
        statusBannerMessage = "Configuration & tabs saved"
    }

    private static func restoreTab(_ saved: SavedTabDescriptor, fallbackPath: String) -> FolderTab {
        let fm = FileManager.default
        let base = saved.lockedBasePath.flatMap { fm.fileExists(atPath: $0) ? $0 : nil }
        let start: String
        if saved.lockState != .unlocked, let base {
            start = base
        } else {
            start = fm.fileExists(atPath: saved.path) ? saved.path : fallbackPath
        }
        return FolderTab(
            customTitle: saved.customTitle,
            currentPath: start,
            lockState: saved.lockState,
            viewMode: saved.viewMode.normalizedForUI,
            sortColumn: saved.sortColumn,
            sortAscending: saved.sortAscending
        )
    }

    public func loadSavedConfiguration() {
        guard let cfg = PersistenceManager.loadConfiguration() else { return }
        self.themeID = cfg.themeID
        self.sizeDisplayFormat = cfg.sizeDisplayFormat
        self.fontSize = cfg.fontSize
        self.isHorizontalSplit = cfg.isHorizontalSplit
        self.showHiddenFiles = cfg.showHiddenFiles
        self.showButtonBar = cfg.showButtonBar
        self.showDriveBar = cfg.showDriveBar
        self.showFunctionKeyBar = cfg.showFunctionKeyBar
        if !cfg.hotlist.isEmpty { self.hotlist = cfg.hotlist }
        if !cfg.remoteProfiles.isEmpty { self.remoteProfiles = cfg.remoteProfiles }
        if !cfg.buttonBarItems.isEmpty {
            self.buttonBarItems = Self.migrateToolbar(cfg.buttonBarItems)
        }
        if !cfg.multiRenamePresets.isEmpty { self.multiRenamePresets = cfg.multiRenamePresets }

        if !cfg.leftTabs.isEmpty {
            leftPanel.tabs = cfg.leftTabs.map { Self.restoreTab($0, fallbackPath: leftPanel.currentPath) }
            leftPanel.activeTabIndex = min(max(0, cfg.leftActiveTabIndex), leftPanel.tabs.count - 1)
            leftPanel.reload()
        }

        if !cfg.rightTabs.isEmpty {
            rightPanel.tabs = cfg.rightTabs.map { Self.restoreTab($0, fallbackPath: rightPanel.currentPath) }
            rightPanel.activeTabIndex = min(max(0, cfg.rightActiveTabIndex), rightPanel.tabs.count - 1)
            rightPanel.reload()
        }
    }
}
