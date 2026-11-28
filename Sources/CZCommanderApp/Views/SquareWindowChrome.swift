import SwiftUI
import AppKit
import CZCommanderCore

// CZ.commander uses a borderless window: macOS always rounds the corners of titled windows,
// so the app draws its own square title bar (drag area + square window buttons).

/// Borderless windows refuse key/main status by default; the commander window needs both.
final class SquareCommanderWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // Window-menu / Cmd+M paths call the "perform" variants, which need real title-bar buttons.
    override func performMiniaturize(_ sender: Any?) { miniaturize(sender) }
    override func performClose(_ sender: Any?) { close() }
    override func performZoom(_ sender: Any?) { CommanderWindowActions.toggleZoom() }
}

@MainActor
enum MainWindowController {
    static var window: SquareCommanderWindow?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let viewModel = CommanderViewModel.shared
        let root = MainCommanderWindowView(viewModel: viewModel)
            .frame(minWidth: 1024, minHeight: 660)
            .background(CommanderKeyCaptureView())
            .onAppear {
                CommanderKeyboardRouter.shared.viewModel = viewModel
                viewModel.mediaPreviewHandler = { panel in QuickLookController.shared.previewMedia(in: panel) }
                FileOperationManager.shared.viewModel = viewModel
                DropboxIntegration.install(viewModel: viewModel)
                viewModel.transferHandler = { sources, destination, isMove, options in
                    if isMove {
                        FileOperationManager.shared.move(sources, to: destination, options: options, background: true)
                    } else {
                        FileOperationManager.shared.copy(sources, to: destination, options: options, background: true)
                    }
                }
                // Snapshot / benchmark runs must not overwrite the user's settings.
                let env = ProcessInfo.processInfo.environment
                if env["CZ_SNAPSHOT_DIR"] == nil || env["CZ_CONFIG_PATH"] != nil {
                    viewModel.startAutosave()
                }
                CommanderKeyboardRouter.shared.installMonitorsIfNeeded()
                CommanderKeyboardRouter.shared.focusKeyCaptureView()
            }

        let window = SquareCommanderWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 860),
            styleMask: [.borderless, .resizable, .miniaturizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "CZ.commander"
        let host = NSHostingView(rootView: root)
        // Performance: don't derive window size constraints from the SwiftUI layout. Otherwise every
        // tiny change (e.g. the status bar text on a cursor move) re-measures the whole window,
        // including the adaptive toolbars. The window's min size is set explicitly below.
        host.sizingOptions = []
        // Host inside a plain container (frame-based), so AppKit never asks SwiftUI for window
        // size constraints during the constraint pass.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 860))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        host.translatesAutoresizingMaskIntoConstraints = true
        container.addSubview(host)
        window.contentView = container
        window.isReleasedWhenClosed = false
        window.hasShadow = true
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.minSize = NSSize(width: 1024, height: 660)
        window.isExcludedFromWindowsMenu = false
        window.animationBehavior = .none
        window.collectionBehavior = [.managed, .participatesInCycle]
        if !window.setFrameUsingName("CZMainWindow") {
            window.center()
        }
        window.setFrameAutosaveName("CZMainWindow")
        Self.window = window
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
enum CommanderWindowActions {
    private static var frameBeforeZoom: NSRect?

    static var window: NSWindow? { MainWindowController.window ?? NSApp.keyWindow }

    static func close() { window?.close() }
    static func minimize() { window?.miniaturize(nil) }

    /// Fills the screen's visible area; a second zoom restores the previous frame.
    static func toggleZoom() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        if window.frame.equalTo(visible), let previous = frameBeforeZoom {
            window.setFrame(previous, display: true, animate: false)
            frameBeforeZoom = nil
        } else {
            frameBeforeZoom = window.frame
            window.setFrame(visible, display: true, animate: false)
        }
    }
}

/// Transparent AppKit view that moves the window on drag and zooms on double click.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                MainActor.assumeIsolated { CommanderWindowActions.toggleZoom() }
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}

/// Square title bar with square close / minimize / zoom buttons.
struct SquareTitleBar: View {
    let palette: CommanderThemePalette
    @State private var hoveringButtons = false

    var body: some View {
        ZStack {
            WindowDragArea()
            HStack(spacing: 7) {
                windowButton(color: Color(red: 1.0, green: 0.37, blue: 0.34), symbol: "xmark",
                             help: "Close") { CommanderWindowActions.close() }
                windowButton(color: Color(red: 1.0, green: 0.74, blue: 0.18), symbol: "minus",
                             help: "Minimize") { CommanderWindowActions.minimize() }
                windowButton(color: Color(red: 0.16, green: 0.79, blue: 0.25), symbol: "arrow.up.left.and.arrow.down.right",
                             help: "Zoom / restore") { CommanderWindowActions.toggleZoom() }
                Spacer()
            }
            .padding(.leading, 10)
            .onHover { hoveringButtons = $0 }
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(true)

            Text("CZ.commander")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(palette.regularFileText.swiftUIColor.opacity(0.75))
                .allowsHitTesting(false)
        }
        .frame(height: 26)
        .background(palette.toolbarBackground.swiftUIColor)
        .overlay(Divider(), alignment: .bottom)
    }

    private func windowButton(color: Color, symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Rectangle().fill(color)
                Rectangle().stroke(Color.black.opacity(0.18), lineWidth: 0.5)
                if hoveringButtons {
                    Image(systemName: symbol)
                        .font(.system(size: 7, weight: .black))
                        .foregroundColor(.black.opacity(0.6))
                }
            }
            .frame(width: 12, height: 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
