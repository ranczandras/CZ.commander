import AppKit
import Quartz
import CZCommanderCore

// F3 on images, video and audio opens macOS Quick Look (the Finder space-bar preview) instead
// of the built-in Lister. Several selected media files can be paged with the arrow keys;
// moving the panel cursor while the preview is open previews the new item.

@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()

    private var urls: [URL] = []

    var isOpen: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    func isPreviewPanel(_ window: NSWindow?) -> Bool {
        guard let window, QLPreviewPanel.sharedPreviewPanelExists() else { return false }
        return window === QLPreviewPanel.shared()
    }

    func show(paths: [String], index: Int = 0) {
        guard !paths.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        urls = paths.map { URL(fileURLWithPath: $0) }
        CommanderKeyboardRouter.shared.focusKeyCaptureView()
        if panel.dataSource == nil || !(panel.dataSource is QuickLookController) {
            panel.dataSource = self
            panel.delegate = self
        }
        panel.reloadData()
        panel.currentPreviewItemIndex = min(max(0, index), urls.count - 1)
        if !panel.isVisible { panel.makeKeyAndOrderFront(nil) }
    }

    func close() {
        guard isOpen else { return }
        QLPreviewPanel.shared().orderOut(nil)
        MainWindowController.window?.makeKeyAndOrderFront(nil)
        CommanderKeyboardRouter.shared.focusKeyCaptureView()
    }

    /// Handles F3 for the panel's cursor / selection. Returns false when the item is not
    /// image / audio / video, so the Lister opens as before.
    func previewMedia(in panel: PanelController) -> Bool {
        if isOpen {
            close()
            return true
        }
        guard let focused = panel.actionableItems.first, PanelController.isQuickLookMedia(focused) else { return false }
        let selected = panel.actionableItems.filter { PanelController.isQuickLookMedia($0) }
        let list = selected.count > 1 ? selected : [focused]
        show(paths: list.map(\.fullPath), index: list.firstIndex { $0.id == panel.focusedItem?.id } ?? 0)
        return true
    }

    /// Keys pressed while the preview panel is key. Returns true when handled.
    func handleKey(_ event: NSEvent, viewModel: CommanderViewModel) -> Bool {
        switch event.keyCode {
        case 53, 99, 49: // Esc, F3, Space
            close()
            return true
        case 125, 126: // Down / Up: move the panel cursor and preview that item
            guard urls.count <= 1 else { return false } // several items: Quick Look pages them
            let panel = viewModel.activePanel
            panel.moveCursor(by: event.keyCode == 125 ? 1 : -1)
            if let item = panel.focusedItem, !item.isParentDirectoryEntry, !item.isDirectory,
               item.archiveContainerPath == nil {
                show(paths: [item.fullPath])
            }
            return true
        default:
            return false
        }
    }

    // MARK: QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated {
            urls.indices.contains(index) ? urls[index] as NSURL : nil
        }
    }
}
