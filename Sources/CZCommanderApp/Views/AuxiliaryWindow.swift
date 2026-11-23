import SwiftUI
import AppKit

// Separate tool windows (YouTube Downloader, App Uninstaller): borderless square windows with
// their own title bar, movable, resizable, minimizable and hideable, so the file panels
// stay usable while they are open. Frames are remembered per window.

@MainActor
enum AuxWindow {
    private static var windows: [String: NSWindow] = [:]

    static func window(_ id: String) -> NSWindow? { windows[id] }

    static func isAuxWindow(_ window: NSWindow) -> Bool {
        windows.values.contains { $0 === window }
    }

    /// Shows the window `id`, creating it with `content` the first time.
    static func show<Content: View>(id: String, title: String, size: NSSize, minSize: NSSize, content: () -> Content) {
        if let window = windows[id] {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }
        let root = VStack(spacing: 0) {
            AuxWindowTitleBar(id: id, title: title)
            content()
        }
        .frame(minWidth: minSize.width, minHeight: minSize.height)
        .background(Color(nsColor: .windowBackgroundColor))

        let window = SquareCommanderWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .resizable, .miniaturizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        host.translatesAutoresizingMaskIntoConstraints = true
        container.addSubview(host)
        window.contentView = container
        window.isReleasedWhenClosed = false
        window.hasShadow = true
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.minSize = minSize
        window.animationBehavior = .none
        window.collectionBehavior = [.managed, .participatesInCycle]
        let autosave = "CZAux-" + id
        if !window.setFrameUsingName(autosave) {
            window.center()
        }
        window.setFrameAutosaveName(autosave)
        windows[id] = window
        window.makeKeyAndOrderFront(nil)
    }

    static func hide(_ id: String) { windows[id]?.orderOut(nil) }
    static func minimize(_ id: String) { windows[id]?.miniaturize(nil) }

    private static var framesBeforeZoom: [String: NSRect] = [:]

    static func toggleZoom(_ id: String) {
        guard let window = windows[id], let screen = window.screen ?? NSScreen.main else { return }
        if let old = framesBeforeZoom.removeValue(forKey: id) {
            window.setFrame(old, display: true)
        } else {
            framesBeforeZoom[id] = window.frame
            window.setFrame(screen.visibleFrame, display: true)
        }
    }
}

/// Square title bar: drag to move, double-click to zoom; close hides the window.
struct AuxWindowTitleBar: View {
    let id: String
    let title: String
    @State private var hovering = false

    var body: some View {
        ZStack {
            AuxWindowDragArea(id: id)
            HStack(spacing: 7) {
                button(Color(red: 1.0, green: 0.37, blue: 0.34), "xmark", "Hide") { AuxWindow.hide(id) }
                button(Color(red: 1.0, green: 0.74, blue: 0.18), "minus", "Minimize") { AuxWindow.minimize(id) }
                button(Color(red: 0.16, green: 0.79, blue: 0.25), "arrow.up.left.and.arrow.down.right", "Zoom / restore") {
                    AuxWindow.toggleZoom(id)
                }
                Spacer()
            }
            .padding(.leading, 10)
            .onHover { hovering = $0 }
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .allowsHitTesting(false)
        }
        .frame(height: 26)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1), alignment: .bottom)
    }

    private func button(_ color: Color, _ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Rectangle().fill(color)
                Rectangle().stroke(Color.black.opacity(0.18), lineWidth: 0.5)
                if hovering {
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

private struct AuxWindowDragArea: NSViewRepresentable {
    let id: String

    func makeNSView(context: Context) -> NSView {
        let v = DragView()
        v.windowID = id
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        var windowID = ""
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                let id = windowID
                MainActor.assumeIsolated { AuxWindow.toggleZoom(id) }
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}
