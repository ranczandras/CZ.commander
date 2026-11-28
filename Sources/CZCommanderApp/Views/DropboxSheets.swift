import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CZCommanderCore

// Dropbox account sheet (sign in / out) and "Open shared link" sheet, plus the app-side hooks
// that turn panel actions into Dropbox jobs.

@MainActor
enum DropboxIntegration {
    /// Installs the hooks once the main window exists.
    static func install(viewModel: CommanderViewModel) {
        let cache = DropboxPanelCache.shared
        cache.onNeedsSignIn = { viewModel.activeSheet = .dropboxAccount }
        cache.onOpenLinkRequested = { panel in viewModel.activeSheet = .dropboxLink(side: panel.side) }
        cache.onOpenFile = { item, _ in
            guard let entry = entry(for: item) else { return }
            // Enter on a Dropbox file: download it to a cache folder and open it.
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CZ.commander/Dropbox Open/" + UUID().uuidString.prefix(8)).path
            FileOperationManager.shared.dropbox(.dropboxDownload(items: [entry], destination: dir, deleteAfter: false, openAfter: true),
                                                title: "Open \"\(entry.name)\" from Dropbox")
        }
        viewModel.dropboxTransferHandler = { items, from, to, isMove in
            let entries = items.compactMap { entry(for: $0) }
            switch (from.dropboxLocation, to.dropboxLocation) {
            case (.some, .none):
                // Dropbox -> Mac
                guard !entries.isEmpty else { return }
                FileOperationManager.shared.dropbox(
                    .dropboxDownload(items: entries, destination: to.currentPath, deleteAfter: isMove, openAfter: false),
                    title: (isMove ? "Move " : "Download ") + FileOperationManager.countText(entries.map(\.name)) + " to " + FileOperationManager.short(to.currentPath))
            case (.none, .some(let dest)):
                // Mac -> Dropbox
                guard dest.supportsWrite else {
                    viewModel.statusBannerMessage = "This Dropbox place is read-only; open a folder of your Dropbox or a shared folder you can edit."
                    return
                }
                let paths = items.map(\.fullPath)
                FileOperationManager.shared.dropbox(
                    .dropboxUpload(paths: paths, destination: dest, options: FileOperationOptions(overwritePolicy: .ask), trashAfter: isMove),
                    title: (isMove ? "Move " : "Upload ") + FileOperationManager.countText(paths) + " to " + dest.displayPath)
            case (.some, .some(let dest)):
                guard dest.supportsWrite, entries.allSatisfy({ $0.location.supportsWrite }) else {
                    viewModel.statusBannerMessage = "Copy from a shared link into your Dropbox is not supported; download it instead."
                    return
                }
                FileOperationManager.shared.dropbox(
                    .dropboxServer(items: entries, destination: dest, isMove: isMove),
                    title: (isMove ? "Move " : "Copy ") + FileOperationManager.countText(entries.map(\.name)) + " to " + dest.displayPath)
            case (.none, .none):
                break
            }
        }
    }

    static func entry(for item: FileItem) -> DropboxEntry? {
        if let e = DropboxPanelCache.shared.entry(forFullPath: item.fullPath) { return e }
        guard let loc = DropboxLocation(fullPath: item.fullPath) else { return nil }
        return DropboxEntry(name: item.name, isFolder: item.isDirectory, size: item.size, modified: item.modificationDate, location: loc)
    }
}

struct DropboxAccountSheetView: View {
    @ObservedObject var viewModel: CommanderViewModel
    @State private var busy = false
    @State private var message: String? = nil
    @State private var signedIn = DropboxClient.shared.isSignedIn

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox.fill").font(.system(size: 20)).foregroundColor(.blue)
                Text("Dropbox").font(.headline)
                Spacer()
            }
            if signedIn {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Signed in" + (DropboxClient.shared.accountName.map { " as " + $0 } ?? ""))
                        .font(.system(size: 13, weight: .semibold))
                    if let email = DropboxClient.shared.accountEmail {
                        Text(email).font(.system(size: 11)).foregroundColor(.secondary)
                    }
                }
                Text("Open Dropbox in the active panel. Copy with F5 / F6 between Dropbox and a local panel. \"⇄ Shared with me\" keeps the shared links you add there with \"＋ Add shared link…\".")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Sign in with your Dropbox account in your web browser. CZ.commander never sees your password; it only gets permission to list, download and upload files. You can revoke it any time on dropbox.com (Settings → Connected apps).")
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message {
                Text(message).font(.system(size: 11.5)).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if signedIn {
                    Button("Sign Out") {
                        DropboxClient.shared.signOut()
                        DropboxPanelCache.shared.invalidateAll()
                        signedIn = false
                        for panel in [viewModel.leftPanel, viewModel.rightPanel] where panel.dropboxLocation != nil {
                            panel.goUp()
                            while panel.dropboxLocation != nil { panel.goUp() }
                        }
                    }
                }
                Spacer()
                Button("Close") { CommanderDialog.close(viewModel) }
                    .keyboardShortcut(.cancelAction)
                if signedIn {
                    Button("Open Dropbox") {
                        CommanderDialog.close(viewModel)
                        viewModel.activePanel.openDropbox()
                    }
                    .buttonStyle(SquareProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(busy ? "Waiting for the browser…" : "Sign in with Dropbox") { signIn() }
                        .buttonStyle(SquareProminentButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func signIn() {
        busy = true
        message = "Allow CZ.commander on the Dropbox page that opened in your browser."
        Task {
            do {
                try await DropboxClient.shared.signIn { url in
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                }
                busy = false
                signedIn = true
                message = nil
                NSApp.activate(ignoringOtherApps: true)
                CommanderDialog.close(viewModel)
                viewModel.activePanel.openDropbox()
            } catch {
                busy = false
                message = error.localizedDescription
            }
        }
    }
}

struct DropboxLinkSheetView: View {
    @ObservedObject var viewModel: CommanderViewModel
    let side: PanelSide
    @State private var link = ""
    @State private var message: String? = nil
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "link").font(.system(size: 16, weight: .bold))
                Text("Add Dropbox shared link").font(.headline)
            }
            Text("Paste a dropbox.com link to a shared folder (or a file). Folders are kept under \"⇄ Shared with me\" and open right away; copy from them with F5. F8 on a link there only takes it off the list.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            TextField("https://www.dropbox.com/scl/fo/…", text: $link)
                .textFieldStyle(SquareTextFieldStyle())
                .font(.system(size: 12, design: .monospaced))
            if let message {
                Text(message).font(.system(size: 11)).foregroundColor(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { CommanderDialog.close(viewModel) }
                    .keyboardShortcut(.cancelAction)
                Button(busy ? "Checking…" : "Add & Open") { open() }
                    .buttonStyle(SquareProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || link.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if let clip = NSPasteboard.general.string(forType: .string), clip.contains("dropbox.com/") {
                link = clip.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private func open() {
        let url = link.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true
        message = nil
        Task {
            do {
                let info = try await DropboxClient.shared.linkInfo(url)
                busy = false
                CommanderDialog.close(viewModel)
                let panel = side == .left ? viewModel.leftPanel : viewModel.rightPanel
                if info.isFolder {
                    DropboxSavedLinks.add(url: url, title: info.name)
                    DropboxPanelCache.shared.invalidate(.sharedWithMe)
                    panel.openDropbox(.link(url: url, path: ""))
                } else {
                    // A single shared file: download it straight into the other panel's folder.
                    let other = side == .left ? viewModel.rightPanel : viewModel.leftPanel
                    let dest = other.dropboxLocation == nil ? other.currentPath : NSHomeDirectory() + "/Downloads"
                    let entry = DropboxEntry(name: info.name, isFolder: false, size: 0, modified: nil, location: .link(url: url, path: ""))
                    FileOperationManager.shared.dropbox(.dropboxDownload(items: [entry], destination: dest, deleteAfter: false, openAfter: false),
                                                        title: "Download \"\(info.name)\" to " + FileOperationManager.short(dest))
                }
            } catch {
                busy = false
                message = error.localizedDescription
            }
        }
    }
}

// MARK: - Drag & drop

/// Pasteboard type that carries Dropbox items between the app's own panels.
let dropboxItemPasteboardType = NSPasteboard.PasteboardType("com.czcommander.dropbox-item")

/// A Dropbox file or folder dragged out of a panel. Finder / the Desktop receive it as a file
/// promise: when dropped, the item is downloaded there with the progress dialog. The app's own
/// panels read the Dropbox path from `dropboxItemPasteboardType` instead.
final class DropboxFilePromiseProvider: NSFilePromiseProvider {
    let fullPath: String

    init(entry: DropboxEntry) {
        fullPath = entry.location.fullPath
        let type = entry.isFolder ? UTType.folder.identifier
            : (UTType(filenameExtension: (entry.name as NSString).pathExtension)?.identifier ?? UTType.data.identifier)
        super.init()
        self.fileType = type
        self.delegate = DropboxPromiseDelegate.shared
        self.userInfo = entry
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [dropboxItemPasteboardType]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == dropboxItemPasteboardType ? fullPath : super.pasteboardPropertyList(forType: type)
    }
}

final class DropboxPromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    static let shared = DropboxPromiseDelegate()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        return q
    }()

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (provider.userInfo as? DropboxEntry)?.name ?? "Dropbox item"
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }

    /// Finder chose `url` (its folder + our name): download there and report when done.
    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        guard let entry = provider.userInfo as? DropboxEntry else {
            completionHandler(DropboxError("Nothing to download."))
            return
        }
        let folder = url.deletingLastPathComponent().path
        let done = DispatchSemaphore(value: 0)
        let box = PromiseResultBox()
        DispatchQueue.main.async {
            FileOperationManager.shared.dropbox(
                .dropboxDownload(items: [entry], destination: folder, deleteAfter: false, openAfter: false),
                title: "Download \"\(entry.name)\" to " + FileOperationManager.short(folder)
            ) { outcome in
                switch outcome {
                case .failed(let message): box.error = DropboxError(message)
                case .cancelled: box.error = DropboxError("Cancelled.")
                default: break
                }
                done.signal()
            }
        }
        done.wait()
        completionHandler(box.error)
    }
}

private final class PromiseResultBox: @unchecked Sendable {
    var error: Error?
}

extension DropboxIntegration {
    static func dragPayload(for item: FileItem) -> FileDragPayload? {
        guard let entry = entry(for: item) else { return nil }
        let icon = entry.isFolder ? NSWorkspace.shared.icon(for: .folder)
            : NSWorkspace.shared.icon(for: UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data)
        return FileDragPayload(writer: DropboxFilePromiseProvider(entry: entry), icon: icon)
    }

    /// Files dropped on a panel: Dropbox items (from the other panel) and / or local files.
    /// Same as F5: download, upload or a server-side copy, with the progress dialog.
    static func handleDrop(dropboxPaths: [String], localPaths: [String], onto panel: PanelController,
                           viewModel: CommanderViewModel) {
        let entries = dropboxPaths.compactMap { path -> DropboxEntry? in
            if let e = DropboxPanelCache.shared.entry(forFullPath: path) { return e }
            guard let loc = DropboxLocation(fullPath: path) else { return nil }
            return DropboxEntry(name: loc.lastName, isFolder: false, size: 0, modified: nil, location: loc)
        }
        if let dest = panel.dropboxLocation {
            let fromHere = entries.filter { $0.location.parent == dest }
            let incoming = entries.filter { $0.location.parent != dest }
            _ = fromHere  // dropped back where it came from
            if !incoming.isEmpty {
                guard dest.supportsWrite, incoming.allSatisfy({ $0.location.supportsWrite }) else {
                    viewModel.statusBannerMessage = "Copy from a shared link into Dropbox is not supported; download it instead."
                    return
                }
                FileOperationManager.shared.dropbox(.dropboxServer(items: incoming, destination: dest, isMove: false),
                                                    title: "Copy " + FileOperationManager.countText(incoming.map(\.name)) + " to " + dest.displayPath)
            }
            if !localPaths.isEmpty {
                guard dest.supportsWrite else {
                    viewModel.statusBannerMessage = "This Dropbox place is read-only."
                    return
                }
                FileOperationManager.shared.dropbox(
                    .dropboxUpload(paths: localPaths, destination: dest, options: FileOperationOptions(overwritePolicy: .ask), trashAfter: false),
                    title: "Upload " + FileOperationManager.countText(localPaths) + " to " + dest.displayPath)
            }
            return
        }
        if !entries.isEmpty {
            FileOperationManager.shared.dropbox(
                .dropboxDownload(items: entries, destination: panel.currentPath, deleteAfter: false, openAfter: false),
                title: "Download " + FileOperationManager.countText(entries.map(\.name)) + " to " + FileOperationManager.short(panel.currentPath))
        }
        let incoming = localPaths.filter { ($0 as NSString).deletingLastPathComponent != panel.currentPath }
        if !incoming.isEmpty {
            FileOperationManager.shared.copy(incoming, to: panel.currentPath)
        }
    }
}
