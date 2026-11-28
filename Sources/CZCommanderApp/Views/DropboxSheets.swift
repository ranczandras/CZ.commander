import SwiftUI
import AppKit
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
                    .dropboxUpload(paths: paths, destination: dest, options: FileOperationOptions(), trashAfter: isMove),
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
                Text("Open Dropbox in the active panel. Copy with F5 / F6 between Dropbox and a local panel; \"⇄ Shared with me\" lists every folder shared with you, \"🔗 Open shared link…\" opens a dropbox.com link.")
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
                Text("Open Dropbox shared link").font(.headline)
            }
            Text("Paste a dropbox.com link to a shared folder or file. It opens in the panel; copy from it with F5.")
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
                Button(busy ? "Opening…" : "Open") { open() }
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
