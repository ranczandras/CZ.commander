import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CZCommanderCore

// App Uninstaller window: pick an app, review everything it left in the Library folders,
// move the app and the ticked items to the Trash (undoable; macOS asks for an administrator
// password for items outside the home folder).

@MainActor
enum AppUninstallerWindowController {
    static let id = "uninstaller"

    static func show(viewModel: CommanderViewModel? = nil) {
        let vm = viewModel ?? CommanderViewModel.shared
        // An .app under the cursor in the active panel opens preselected.
        let candidate = vm.activePanel.focusedItem.map(\.fullPath).flatMap { path -> String? in
            path.lowercased().hasSuffix(".app") ? path : nil
        }
        AuxWindow.show(id: id, title: "App Uninstaller", size: NSSize(width: 1000, height: 660),
                       minSize: NSSize(width: 820, height: 480)) {
            AppUninstallerView(viewModel: vm)
        }
        if let candidate { AppUninstallerSession.shared.select(path: candidate) }
    }

    static func hide() { AuxWindow.hide(id) }
}

/// Opens the separate window when `.appUninstaller` is requested through the sheet slot.
struct AppUninstallerLauncher: View {
    @ObservedObject var viewModel: CommanderViewModel

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {
                viewModel.activeSheet = nil
                AppUninstallerWindowController.show(viewModel: viewModel)
            }
    }
}

@MainActor
final class AppUninstallerSession: ObservableObject {
    static let shared = AppUninstallerSession()

    enum Phase: Equatable {
        case idle
        case confirming
        case working(String)
    }

    struct Report: Equatable {
        let appName: String
        let movedCount: Int
        let movedBytes: Int64
        let failures: [String]
    }

    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var appSizes: [String: Int64] = [:]
    @Published private(set) var isLoadingApps = false
    private var hasLoadedApps = false
    @Published var search = ""
    @Published var sortBySize = false
    @Published private(set) var selectedPath: String? = nil
    @Published private(set) var plan: AppUninstallPlan? = nil
    @Published private(set) var isPlanning = false
    @Published var ticked: Set<String> = []
    @Published var phase: Phase = .idle
    @Published var report: Report? = nil

    private var generation = 0
    private var sizeGeneration = 0

    var filteredApps: [InstalledApp] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        var list = q.isEmpty ? apps : apps.filter {
            $0.name.lowercased().contains(q) || ($0.bundleID?.lowercased().contains(q) ?? false)
        }
        if sortBySize {
            list.sort { (appSizes[$0.path] ?? -1) > (appSizes[$1.path] ?? -1) }
        }
        return list
    }

    var selectedApp: InstalledApp? {
        guard let selectedPath else { return nil }
        return apps.first { $0.path == selectedPath } ?? plan?.app
    }

    var tickedLeftovers: [AppLeftover] { plan?.leftovers.filter { ticked.contains($0.path) } ?? [] }

    var totalBytes: Int64 {
        (plan?.bundleSize ?? 0) + tickedLeftovers.reduce(0) { $0 + $1.sizeBytes }
    }

    func isRunning(_ app: InstalledApp) -> Bool {
        NSWorkspace.shared.runningApplications.contains { running in
            running.bundleURL?.standardizedFileURL.path == app.path
                || (app.bundleID != nil && running.bundleIdentifier == app.bundleID)
        }
    }

    // MARK: Loading

    func loadAppsIfNeeded() {
        if !hasLoadedApps { loadApps() }
    }

    func loadApps() {
        guard !isLoadingApps else { return }
        isLoadingApps = true
        Task.detached(priority: .userInitiated) {
            let list = AppUninstallEngine.listApps()
            await MainActor.run {
                let s = AppUninstallerSession.shared
                // Keep an app that was opened from elsewhere (dropped, panel cursor).
                let extra = s.apps.filter { a in !list.contains { $0.path == a.path } }
                s.apps = (list + extra).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                s.hasLoadedApps = true
                s.isLoadingApps = false
                s.measureApps(list)
            }
        }
    }

    private func measureApps(_ list: [InstalledApp]) {
        sizeGeneration += 1
        let gen = sizeGeneration
        let missing = list.filter { appSizes[$0.path] == nil }
        Task.detached(priority: .utility) {
            var batch: [String: Int64] = [:]
            for (i, app) in missing.enumerated() {
                batch[app.path] = AppUninstallEngine.allocatedSize(app.path)
                if batch.count >= 8 || i == missing.count - 1 {
                    let done = batch
                    batch.removeAll()
                    let stop = await MainActor.run { () -> Bool in
                        let s = AppUninstallerSession.shared
                        guard s.sizeGeneration == gen else { return true }
                        s.appSizes.merge(done) { _, new in new }
                        return false
                    }
                    if stop { return }
                }
            }
        }
    }

    func select(path: String) {
        guard selectedPath != path || plan == nil else { return }
        if !apps.contains(where: { $0.path == path }), let app = AppUninstallEngine.loadApp(at: path) {
            apps.append(app)
            apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        selectedPath = path
        plan = nil
        ticked = []
        phase = .idle
        guard let app = apps.first(where: { $0.path == path }) else { return }
        generation += 1
        let gen = generation
        isPlanning = true
        Task.detached(priority: .userInitiated) {
            let p = AppUninstallEngine.plan(for: app)
            await MainActor.run {
                let s = AppUninstallerSession.shared
                guard s.generation == gen else { return }
                s.plan = p
                s.ticked = Set(p.leftovers.filter(\.preselected).map(\.path))
                s.appSizes[app.path] = p.bundleSize
                s.isPlanning = false
            }
        }
    }

    func toggle(_ path: String) {
        if ticked.contains(path) { ticked.remove(path) } else { ticked.insert(path) }
    }

    // MARK: Uninstall

    func uninstall() {
        guard let plan, plan.app.protectionReason == nil else { return }
        let app = plan.app
        let leftovers = tickedLeftovers
        phase = .working("Quitting \(app.name)…")
        report = nil

        Task { @MainActor in
            // 1. Quit the app (and wait for it).
            if isRunning(app) {
                for running in NSWorkspace.shared.runningApplications
                where running.bundleURL?.standardizedFileURL.path == app.path || running.bundleIdentifier == app.bundleID {
                    running.terminate()
                }
                for _ in 0..<40 where isRunning(app) {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
                if isRunning(app) {
                    phase = .idle
                    report = Report(appName: app.name, movedCount: 0, movedBytes: 0,
                                    failures: ["\(app.name) did not quit. Quit it yourself, then try again."])
                    return
                }
            }

            // 2. Stop the user's launch agents before their files go.
            phase = .working("Stopping background agents…")
            let uid = getuid()
            for item in leftovers where !item.needsAdmin {
                if let label = item.launchLabel {
                    _ = await Self.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
                }
            }

            // 3. Move everything to the Trash in one go (one password prompt at most).
            phase = .working("Moving to the Trash…")
            let urls = [URL(fileURLWithPath: app.path)] + leftovers.map { URL(fileURLWithPath: $0.path) }
            let sizes = Dictionary(uniqueKeysWithValues: [(app.path, plan.bundleSize)] + leftovers.map { ($0.path, $0.sizeBytes) })
            var failures: [String] = []
            do {
                _ = try await NSWorkspace.shared.recycle(urls)
            } catch {
                failures.append(error.localizedDescription)
            }
            // A partial failure (e.g. password prompt cancelled) still moves the rest.
            var movedPaths = Set<String>()
            for url in urls {
                if FileManager.default.fileExists(atPath: url.path) || AppUninstallEngine.isSymlinkPath(url.path) {
                    failures.append("Not moved: " + url.path)
                } else {
                    movedPaths.insert(url.path)
                }
            }
            let bytes = movedPaths.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
            report = Report(appName: app.name, movedCount: movedPaths.count, movedBytes: bytes, failures: failures)
            phase = .idle

            if !FileManager.default.fileExists(atPath: app.path) {
                apps.removeAll { $0.path == app.path }
                appSizes[app.path] = nil
                selectedPath = nil
                self.plan = nil
                ticked = []
            } else {
                select(path: app.path)
            }
        }
    }

    nonisolated static func run(_ tool: String, _ args: [String]) async -> Int32 {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { cont.resume(returning: -1) }
        }
    }
}

// MARK: - View

struct AppUninstallerView: View {
    @ObservedObject var viewModel: CommanderViewModel
    @ObservedObject private var session = AppUninstallerSession.shared
    @State private var isDropTarget = false

    private func size(_ bytes: Int64) -> String { FileItem.formatByteCount(bytes) }

    var body: some View {
        HStack(spacing: 0) {
            appList
                .frame(width: 320)
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { session.loadAppsIfNeeded() }
        .onExitCommand { AppUninstallerWindowController.hide() }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTarget) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension.lowercased() == "app" else { return }
                let path = url.standardizedFileURL.path
                DispatchQueue.main.async { AppUninstallerSession.shared.select(path: path) }
            }
            return true
        }
        .overlay(isDropTarget ? Rectangle().stroke(Color.accentColor, lineWidth: 3) : nil)
    }

    // MARK: App list

    private var appList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search apps", text: $session.search)
                    .textFieldStyle(SquareTextFieldStyle())
            }
            HStack(spacing: 8) {
                SquarePicker("", selection: $session.sortBySize,
                             options: [(false, "By name"), (true, "By size")], kind: .segmented)
                    .frame(width: 160)
                Spacer()
                Button {
                    session.loadApps()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload the list of apps")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if session.isLoadingApps && session.apps.isEmpty {
                        Text("Loading apps…")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .padding(10)
                    }
                    ForEach(session.filteredApps) { app in
                        appRow(app)
                    }
                }
            }
            .background(Rectangle().fill(Color.primary.opacity(0.03)))
            .overlay(Rectangle().stroke(Color(nsColor: .separatorColor), lineWidth: 1))
            Text("\(session.apps.count) apps in /Applications and ~/Applications. Drop any .app here.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(12)
    }

    private func appRow(_ app: InstalledApp) -> some View {
        let isSelected = app.path == session.selectedPath
        return Button {
            session.select(path: app.path)
        } label: {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                    .resizable()
                    .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(app.name)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    if let v = app.version {
                        Text(v)
                            .font(.system(size: 9.5))
                            .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if app.protectionReason != nil {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                }
                Text(session.appSizes[app.path].map(size) ?? "…")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(isSelected ? .white.opacity(0.9) : .secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Rectangle().fill(isSelected ? Color.accentColor : Color.clear))
            .foregroundColor(isSelected ? .white : .primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(app.path)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let report = session.report {
                reportBanner(report)
            }
            if let app = session.selectedApp {
                appHeader(app)
                if let reason = app.protectionReason {
                    notice(reason + " It cannot be removed here.", color: .secondary, symbol: "lock.fill")
                    Spacer()
                } else if session.isPlanning || session.plan == nil {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for files that belong to \(app.name)…")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let plan = session.plan {
                    if let vendor = AppUninstallEngine.vendorUninstaller(for: app.path) {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle.fill").foregroundColor(.blue)
                            Text("\(app.name) has its own uninstaller. It also removes licences and shared components; use it first, then come back here for the leftovers.")
                                .font(.system(size: 11))
                            Spacer()
                            Button("Open \(((vendor as NSString).lastPathComponent as NSString).deletingPathExtension)") {
                                NSWorkspace.shared.open(URL(fileURLWithPath: vendor))
                            }
                        }
                        .padding(8)
                        .background(Rectangle().fill(Color.blue.opacity(0.08)))
                        .overlay(Rectangle().stroke(Color.blue.opacity(0.4), lineWidth: 1))
                    }
                    leftoverList(plan)
                    footer(plan)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "xmark.bin")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("Pick an app on the left, or drop an .app here.")
                        .font(.system(size: 13))
                    Text("Everything it left behind is listed for review: support files, caches, preferences, containers, background agents, logs and crash reports. All of it goes to the Trash, so it can be put back.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(14)
    }

    private func appHeader(_ app: InstalledApp) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(app.name).font(.system(size: 17, weight: .bold))
                    if let v = app.version {
                        Text(v).font(.system(size: 12)).foregroundColor(.secondary)
                    }
                    if app.isAppStore { badge("APP STORE", .blue) }
                    if session.isRunning(app) { badge("RUNNING", .orange) }
                }
                Text(app.bundleID ?? "no bundle identifier")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                Text(app.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Show in Panel") { showInPanel(app.path) }
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .foregroundColor(color)
            .overlay(Rectangle().stroke(color, lineWidth: 0.8))
    }

    private func leftoverList(_ plan: AppUninstallPlan) -> some View {
        let groups = Dictionary(grouping: plan.leftovers, by: \.category)
        let categoryOrder = plan.leftovers.map(\.category).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                sectionHeader("Application", bytes: plan.bundleSize)
                leftoverRow(path: plan.app.path, sizeBytes: plan.bundleSize, isOn: true, locked: true,
                            admin: !plan.app.path.hasPrefix(NSHomeDirectory() + "/"), note: nil) {}
                if plan.leftovers.isEmpty {
                    Text("No other files found for this app.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(10)
                }
                ForEach(categoryOrder, id: \.self) { category in
                    let items = groups[category] ?? []
                    sectionHeader(category, bytes: items.reduce(0) { $0 + $1.sizeBytes })
                    ForEach(items) { item in
                        leftoverRow(path: item.path, sizeBytes: item.sizeBytes, isOn: session.ticked.contains(item.path),
                                    locked: false, admin: item.needsAdmin,
                                    note: note(for: item.match)) {
                            session.toggle(item.path)
                        }
                    }
                }
            }
        }
        .background(Rectangle().fill(Color.primary.opacity(0.03)))
        .overlay(Rectangle().stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }

    private func note(for match: AppLeftoverMatch) -> String? {
        switch match {
        case .bundleID: return nil
        case .name: return "matched by name"
        case .related: return "check: may belong to another app"
        case .team: return "check: shared with the vendor's other apps?"
        }
    }

    private func sectionHeader(_ title: String, bytes: Int64) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
            Spacer()
            Text(size(bytes))
                .font(.system(size: 10, design: .monospaced))
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 3)
    }

    private func leftoverRow(path: String, sizeBytes: Int64, isOn: Bool, locked: Bool, admin: Bool, note: String?, toggle: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { isOn }, set: { _ in toggle() }))
                .toggleStyle(SquareCheckboxToggleStyle())
                .disabled(locked)
                .labelsHidden()
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Text((path as NSString).lastPathComponent)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                    if admin {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                            .help("Outside your home folder: macOS asks for an administrator password")
                    }
                    if let note {
                        Text(note)
                            .font(.system(size: 9.5))
                            .foregroundColor(.orange)
                    }
                }
                Text((path as NSString).deletingLastPathComponent)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            Text(size(sizeBytes))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(.secondary)
            Button {
                showInPanel(path)
            } label: {
                Image(systemName: "arrow.right.circle")
            }
            .buttonStyle(.plain)
            .help("Show in the active panel")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .help(path)
    }

    @ViewBuilder
    private func footer(_ plan: AppUninstallPlan) -> some View {
        let count = session.tickedLeftovers.count
        switch session.phase {
        case .working(let text):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text).font(.system(size: 11.5))
                Spacer()
            }
        case .confirming:
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Move \(plan.app.name) and \(count) related item(s), \(size(session.totalBytes)), to the Trash?")
                        .font(.system(size: 12, weight: .semibold))
                    Text(confirmDetail(plan))
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Cancel") { session.phase = .idle }
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash") { session.uninstall() }
                    .buttonStyle(SquareProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(8)
            .background(Rectangle().fill(Color.red.opacity(0.08)))
            .overlay(Rectangle().stroke(Color.red.opacity(0.5), lineWidth: 1))
        case .idle:
            HStack(spacing: 10) {
                Button("Select all") { session.ticked = Set(plan.leftovers.map(\.path)) }
                Button("Select none") { session.ticked = [] }
                Spacer()
                Text("App + \(count) item(s): \(size(session.totalBytes))")
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                Button("Hide") { AppUninstallerWindowController.hide() }
                Button("Uninstall…") { session.phase = .confirming }
                    .buttonStyle(SquareProminentButtonStyle())
            }
        }
    }

    private func confirmDetail(_ plan: AppUninstallPlan) -> String {
        var parts: [String] = ["Undoable: everything can be put back from the Trash."]
        if session.isRunning(plan.app) { parts.append("\(plan.app.name) is running and will be quit first.") }
        let admin = session.tickedLeftovers.contains(where: \.needsAdmin) || !plan.app.path.hasPrefix(NSHomeDirectory() + "/")
        if admin { parts.append("macOS may ask for an administrator password.") }
        return parts.joined(separator: " ")
    }

    private func reportBanner(_ report: AppUninstallerSession.Report) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: report.failures.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(report.failures.isEmpty ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(report.movedCount > 0
                     ? "\(report.appName): moved \(report.movedCount) item(s), \(size(report.movedBytes)), to the Trash."
                     : "\(report.appName) was not removed.")
                    .font(.system(size: 12, weight: .semibold))
                ForEach(report.failures.prefix(6), id: \.self) { f in
                    Text(f)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Button("Dismiss") { session.report = nil }
        }
        .padding(8)
        .background(Rectangle().fill(Color.primary.opacity(0.05)))
        .overlay(Rectangle().stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }

    private func notice(_ text: String, color: Color, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundColor(color)
            Text(text).font(.system(size: 12))
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Rectangle().fill(Color.primary.opacity(0.05)))
    }

    private func showInPanel(_ path: String) {
        let parent = (path as NSString).deletingLastPathComponent
        viewModel.activePanel.navigateTo(path: parent, selectingChildNamed: (path as NSString).lastPathComponent)
        MainWindowController.show()
    }
}
