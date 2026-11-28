import Foundation

// Dropbox inside a file panel: listings load in the background and are cached per folder, the
// panel shows "Loading…" meanwhile and redraws when they arrive.

@MainActor
public final class DropboxPanelCache {
    public static let shared = DropboxPanelCache()

    struct Listing {
        var entries: [DropboxEntry]
        var error: String?
        var fetchedAt: Date
    }

    private var listings: [String: Listing] = [:]
    private var loading: Set<String> = []
    /// fullPath -> entry, so transfers know sizes and kinds of the items shown.
    private var entriesByPath: [String: DropboxEntry] = [:]

    /// Called when a panel needs a sign-in (set by the app: shows the sign-in sheet).
    public var onNeedsSignIn: (() -> Void)?
    /// Enter on a Dropbox file (app: downloads it to a temporary folder and opens it).
    public var onOpenFile: ((FileItem, PanelController) -> Void)?
    /// Called when a panel entered the "Open shared link…" item (app: asks for the link).
    public var onOpenLinkRequested: ((PanelController) -> Void)?

    public static let openLinkPath = "dbx-action:open-link"
    public static let loadingPath = "dbx-action:loading"

    public func entry(forFullPath path: String) -> DropboxEntry? { entriesByPath[path] }

    /// Name to put the cursor on once a listing that is still loading arrives, per panel.
    private var pendingSelection: [ObjectIdentifier: String] = [:]

    func setPendingSelection(_ name: String?, for panel: PanelController) {
        pendingSelection[ObjectIdentifier(panel)] = name
    }

    func takePendingSelection(for panel: PanelController) -> String? {
        pendingSelection.removeValue(forKey: ObjectIdentifier(panel))
    }

    public func invalidate(_ location: DropboxLocation) { listings[location.token] = nil }
    public func invalidateAll() { listings.removeAll() }

    /// Items for the panel, or nil while loading (a fetch is started; `onLoaded` redraws).
    func items(for location: DropboxLocation, onLoaded: @escaping @MainActor () -> Void) -> (items: [FileItem]?, error: String?) {
        if let listing = listings[location.token] {
            return (listing.entries.map { $0.fileItem() }, listing.error)
        }
        if !loading.contains(location.token) {
            loading.insert(location.token)
            let token = location.token
            Task.detached(priority: .userInitiated) {
                var entries: [DropboxEntry] = []
                var message: String?
                do {
                    entries = try await DropboxClient.shared.list(location)
                } catch {
                    message = error.localizedDescription
                }
                let result = entries
                let err = message
                await MainActor.run {
                    let cache = DropboxPanelCache.shared
                    cache.loading.remove(token)
                    cache.listings[token] = Listing(entries: result, error: err, fetchedAt: Date())
                    for e in result { cache.entriesByPath[e.location.fullPath] = e }
                    onLoaded()
                }
            }
        }
        return (nil, nil)
    }
}

extension PanelController {
    /// The Dropbox place shown, if this panel is in Dropbox.
    public var dropboxLocation: DropboxLocation? {
        if case .dropbox(let loc, _) = activeTab.vfsMode { return loc }
        return nil
    }

    /// Opens a Dropbox place in this panel (asks for sign-in first when needed).
    public func openDropbox(_ location: DropboxLocation = .own("/"), selecting name: String? = nil) {
        var origin = activeTab.currentPath
        if case .dropbox(_, let o) = activeTab.vfsMode { origin = o }
        if DropboxLocation.isDropboxPath(origin) { origin = NSHomeDirectory() }
        guard DropboxClient.shared.isSignedIn else {
            DropboxPanelCache.shared.onNeedsSignIn?()
            return
        }
        if activeTab.currentPath != location.fullPath {
            activeTab.historyBackStack.append(activeTab.currentPath)
            activeTab.historyForwardStack.removeAll()
        }
        activeTab.vfsMode = .dropbox(location: location, origin: origin)
        DropboxPanelCache.shared.setPendingSelection(name, for: self)
        activeTab.currentPath = location.fullPath
        activeTab.quickFilter = ""
        isQuickFilterVisible = false
        clearSelection()
        cursorItemID = nil
        cursorIndex = 0
        reload(selectingItemNamed: name)
    }

    /// Reloads the listing from Dropbox (F2 / after changes).
    public func refreshDropbox() {
        guard let loc = dropboxLocation else { return }
        DropboxPanelCache.shared.invalidate(loc)
        reload()
    }

    func dropboxRawItems(_ location: DropboxLocation, origin: String) -> (items: [FileItem], error: String?) {
        let parentPath = location.isRoot && location == .own("/") ? origin : location.parent.fullPath
        var items = [FileItem.parentEntry(for: parentPath)]
        guard DropboxClient.shared.isSignedIn else {
            return (items, "Not signed in to Dropbox.")
        }
        let token = location.token
        let (listed, error) = DropboxPanelCache.shared.items(for: location) { [weak self] in
            guard let self, self.dropboxLocation?.token == token else { return }
            // Select what was asked for when the folder opened (the folder we came back from).
            let wanted = DropboxPanelCache.shared.takePendingSelection(for: self)
            self.reload(selectingItemNamed: wanted)
        }
        if location == .own("/") {
            var shared = FileItem(name: "⇄ Shared with me", fullPath: DropboxLocation.sharedWithMe.fullPath, isDirectory: true)
            shared.modificationDate = Date.distantPast
            items.append(shared)
        }
        if location == .sharedWithMe {
            var link = FileItem(name: "＋ Add shared link…", fullPath: DropboxPanelCache.openLinkPath, isDirectory: true)
            link.modificationDate = Date.distantPast
            items.append(link)
        }
        guard let listed else {
            var loading = FileItem(name: "Loading from Dropbox…", fullPath: DropboxPanelCache.loadingPath, isDirectory: false)
            loading.modificationDate = Date.distantPast
            items.append(loading)
            return (items, nil)
        }
        items.append(contentsOf: listed)
        return (items, error)
    }

    func enterDropboxItem(_ item: FileItem) -> Bool {
        if item.fullPath == DropboxPanelCache.openLinkPath {
            DropboxPanelCache.shared.onOpenLinkRequested?(self)
            return true
        }
        if item.fullPath == DropboxPanelCache.loadingPath { return true }
        guard let loc = DropboxLocation(fullPath: item.fullPath) else { return false }
        if item.isDirectory {
            openDropbox(loc)
            return true
        }
        return false
    }

    func dropboxGoUp(_ location: DropboxLocation, origin: String) {
        if location == .own("/") {
            navigateTo(path: origin)
            return
        }
        let exited = location == .sharedWithMe ? "⇄ Shared with me" : location.lastName
        let parent: DropboxLocation
        if case .link = location, location.isRoot { parent = .own("/") } else { parent = location.parent }
        openDropbox(parent, selecting: exited)
    }
}
