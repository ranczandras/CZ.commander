import SwiftUI
import AppKit
import CZCommanderCore

// Startup Items window: shows what macOS starts at login or boot and lets you turn single
// items off and on again. Turning an item off never deletes anything (see docs/STARTUP.md).

@MainActor
enum StartupWindowController {
    static let id = "startup"

    static func show(viewModel: CommanderViewModel? = nil) {
        let vm = viewModel ?? CommanderViewModel.shared
        AuxWindow.show(id: id, title: "Startup Items", size: NSSize(width: 980, height: 660),
                       minSize: NSSize(width: 780, height: 460)) {
            StartupView(viewModel: vm)
        }
        StartupSession.shared.reload()
    }

    static func hide() { AuxWindow.hide(id) }
}

/// Opens the separate window when `.startup` is requested through the sheet slot.
struct StartupLauncher: View {
    @ObservedObject var viewModel: CommanderViewModel

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {
                viewModel.activeSheet = nil
                StartupWindowController.show(viewModel: viewModel)
            }
    }
}

@MainActor
final class StartupSession: ObservableObject {
    static let shared = StartupSession()

    @Published private(set) var items: [StartupItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loginItemsError: String? = nil
    @Published private(set) var loginItemsNeedPermission = false
    @Published private(set) var unreadablePlists: [String] = []
    @Published private(set) var busy: Set<String> = []
    @Published private(set) var statusText: String? = nil
    @Published private(set) var statusIsError = false
    @Published var search = ""
    @Published var showOnDemand = false
    @Published var showApple = false

    private var generation = 0
    private var hasLoaded = false

    func loadIfNeeded() {
        if !hasLoaded { reload() }
    }

    func reload() {
        hasLoaded = true
        generation += 1
        let gen = generation
        isLoading = true
        let env = StartupEnvironment.current()
        Task.detached(priority: .userInitiated) {
            let result = StartupEngine.scan(environment: env)
            await MainActor.run {
                guard gen == StartupSession.shared.generation else { return }
                let session = StartupSession.shared
                session.items = result.items
                session.loginItemsError = result.loginItemsError
                session.loginItemsNeedPermission = result.loginItemsNeedPermission
                session.unreadablePlists = result.unreadablePlists
                session.isLoading = false
            }
        }
    }

    func set(_ item: StartupItem, enabled: Bool) {
        guard item.canToggle, !busy.contains(item.id) else { return }
        busy.insert(item.id)
        let env = StartupEnvironment.current()
        Task.detached(priority: .userInitiated) {
            let result = StartupEngine.setEnabled(item, to: enabled, environment: env)
            await MainActor.run {
                let session = StartupSession.shared
                session.busy.remove(item.id)
                session.statusText = result.message
                session.statusIsError = !result.success
                session.reload()
            }
        }
    }

    func dismissStatus() { statusText = nil }

    var visibleItems: [StartupItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return items.filter { item in
            if item.isApple && !showApple { return false }
            // Helpers that only start on demand are noise, unless they were turned off here.
            if item.trigger == .onDemand && item.enabled && !showOnDemand { return false }
            if q.isEmpty { return true }
            return item.name.lowercased().contains(q) || (item.label?.lowercased().contains(q) ?? false)
                || (item.programPath?.lowercased().contains(q) ?? false)
        }
    }

    var startAtLoginCount: Int { items.filter { $0.enabled && $0.trigger == .atLogin && !$0.isApple }.count }
    var turnedOffCount: Int { items.filter { !$0.enabled && !$0.isApple }.count }
}

struct StartupView: View {
    @ObservedObject var viewModel: CommanderViewModel
    @ObservedObject private var session = StartupSession.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let text = session.statusText { statusBanner(text) }
            if let error = session.loginItemsError { loginItemsBanner(error) }
            filterBar
            list
            footer
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { session.loadIfNeeded() }
        .onExitCommand { StartupWindowController.hide() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "power")
                .font(.system(size: 20, weight: .bold))
            VStack(alignment: .leading, spacing: 2) {
                Text("Startup Items").font(.headline)
                Text("Tick = starts as set up, untick = turned off. Nothing is deleted: turning an item off is undone by ticking it again.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if session.isLoading {
                Text("Reading…").font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                Text("\(session.startAtLoginCount) start at login · \(session.turnedOffCount) turned off")
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
            }
            Button {
                session.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Read the lists again")
        }
    }

    private func statusBanner(_ text: String) -> some View {
        let color: Color = session.statusIsError ? .red : .green
        return HStack(spacing: 8) {
            Image(systemName: session.statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundColor(color)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Dismiss") { session.dismissStatus() }
        }
        .padding(8)
        .background(Rectangle().fill(color.opacity(0.1)))
        .overlay(Rectangle().stroke(color.opacity(0.5), lineWidth: 1))
    }

    private func loginItemsBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield.fill").foregroundColor(.orange)
            Text("The Login Items list could not be read: \(error)")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if session.loginItemsNeedPermission {
                Button("Open Automation settings…") {
                    open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
                }
            }
        }
        .padding(8)
        .background(Rectangle().fill(Color.orange.opacity(0.12)))
        .overlay(Rectangle().stroke(Color.orange.opacity(0.5), lineWidth: 1))
    }

    // MARK: Filters

    private var filterBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("Search name, label or path", text: $session.search)
                .textFieldStyle(SquareTextFieldStyle())
                .frame(maxWidth: 320)
            Toggle("Also show helpers that start only on demand", isOn: $session.showOnDemand)
                .font(.system(size: 11))
            Toggle("Show Apple items", isOn: $session.showApple)
                .font(.system(size: 11))
            Spacer()
        }
    }

    // MARK: List

    private var list: some View {
        let visible = session.visibleItems
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if visible.isEmpty {
                    Text(session.isLoading ? "Reading…" : "Nothing to show.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .padding(16)
                }
                ForEach(StartupItemKind.allCases, id: \.self) { kind in
                    let group = visible.filter { $0.kind == kind }
                    if !group.isEmpty {
                        sectionHeader(kind, count: group.count)
                        ForEach(group) { item in row(item) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Rectangle().fill(Color.primary.opacity(0.03)))
        .overlay(Rectangle().stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }

    private func sectionHeader(_ kind: StartupItemKind, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) {
                Image(systemName: kind.symbolName).font(.system(size: 12)).frame(width: 18)
                Text(kind.title).font(.system(size: 12.5, weight: .bold))
                Text("\(count)").font(.system(size: 11)).foregroundColor(.secondary)
            }
            Text(kind.detail)
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.07))
        .overlay(Divider(), alignment: .bottom)
    }

    private func row(_ item: StartupItem) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Group {
                if session.busy.contains(item.id) {
                    ProgressView().controlSize(.small).frame(width: 13, height: 13)
                } else {
                    CleanupCheckbox(state: item.enabled ? .on : .off) {
                        session.set(item, enabled: !item.enabled)
                    }
                    .opacity(item.canToggle ? 1 : 0.3)
                    .allowsHitTesting(item.canToggle)
                    .help(item.toggleBlockedReason ?? (item.enabled ? "Turn off" : "Turn on"))
                }
            }
            .padding(.top, 3)
            icon(item)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    if !item.canToggle { badge(item.kind == .systemDaemon ? "admin only" : "locked", color: .gray) }
                    if item.runState == .running { badge("running", color: .green) }
                    if item.programMissing { badge("program missing", color: .orange) }
                    if item.cautionReason != nil { badge("security / VPN", color: .red) }
                    if item.removedByUs { badge("removed from the list", color: .blue) }
                    if item.loginItemHidden { badge("hidden", color: .gray) }
                }
                Text(subtitle(item))
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let reason = item.cautionReason {
                    Text(reason).font(.system(size: 10.5)).foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if item.programMissing, item.kind != .loginItem {
                    Text("The program this item starts no longer exists, so it does nothing. It is usually left behind by an uninstalled app.")
                        .font(.system(size: 10.5)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let blocked = item.toggleBlockedReason {
                    Text(blocked).font(.system(size: 10.5)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if revealPath(item) != nil {
                Button("Show") { reveal(item) }
                    .controlSize(.small)
                    .help("Show the file in the active panel")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .opacity(item.enabled ? 1 : 0.65)
        .overlay(Divider(), alignment: .bottom)
        .help(item.plistPath ?? item.programPath ?? "")
    }

    @ViewBuilder
    private func icon(_ item: StartupItem) -> some View {
        if let app = item.appPath, FileManager.default.fileExists(atPath: app) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app))
                .resizable()
                .frame(width: 22, height: 22)
        } else {
            Image(systemName: item.kind.symbolName)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .frame(width: 22, height: 22)
        }
    }

    private func subtitle(_ item: StartupItem) -> String {
        var parts: [String] = [item.kind == .loginItem ? "Opens at login" : item.trigger.text]
        if item.keepsRunning { parts.append("restarted when it quits") }
        if let program = item.programPath, !program.isEmpty { parts.append(program) }
        else if let label = item.label { parts.append(label) }
        return parts.joined(separator: " · ")
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Rectangle().fill(color.opacity(0.18)))
            .overlay(Rectangle().stroke(color.opacity(0.6), lineWidth: 0.8))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Apps that registered through \"Allow in the Background\" can only be switched in System Settings.")
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
            Spacer()
            Button("Login Items & Extensions settings…") {
                open("x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
            }
            Button("Close") { StartupWindowController.hide() }
                .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: Helpers

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    private func revealPath(_ item: StartupItem) -> String? {
        let path = item.plistPath ?? item.appPath ?? item.programPath
        guard let path, !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    /// Opens the item's folder in the active panel and puts the cursor on it.
    private func reveal(_ item: StartupItem) {
        guard let path = revealPath(item) else { return }
        viewModel.activePanel.navigateTo(path: (path as NSString).deletingLastPathComponent,
                                         selectingChildNamed: (path as NSString).lastPathComponent)
    }
}
