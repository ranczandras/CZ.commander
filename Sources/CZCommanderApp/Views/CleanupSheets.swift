import SwiftUI
import AppKit
import CZCommanderCore

// Cleanup window: scan -> pick categories / groups / single items -> confirm -> delete.
// What is scanned and why is documented in docs/CLEANUP.md.

/// Lets a background scan report progress without flooding the main thread.
final class CleanupProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast

    func shouldEmit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if now.timeIntervalSince(last) < 0.08 { return false }
        last = now
        return true
    }
}

enum CleanupCheckState {
    case on, off, mixed
}

enum CleanupRow: Identifiable {
    case category(CleanupCategoryResult)
    case group(CleanupGroupResult)
    case item(CleanupItem)

    var id: String {
        switch self {
        case .category(let c): return "c:" + c.id
        case .group(let g): return "g:" + g.id
        case .item(let i): return "i:" + i.id
        }
    }
}

@MainActor
final class CleanupSession: ObservableObject {
    enum Phase {
        case scanning, results, cleaning
    }

    @Published var phase: Phase = .scanning
    @Published var progress: CleanupProgress? = nil
    @Published var result: CleanupScanResult? = nil
    @Published var selected: Set<String> = []
    @Published var collapsedCategories: Set<String> = []
    @Published var expandedGroups: Set<String> = []
    @Published var report: CleanupDeleteReport? = nil
    @Published var isConfirming = false
    @Published var moveToTrash = false

    private var cancellation = CleanupCancellation()
    private var generation = 0

    nonisolated static func environment() -> CleanupEnvironment {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        return CleanupEnvironment.current(runningBundleIDs: running)
    }

    func cancel() {
        cancellation.cancel()
    }

    func scan(keepReport: Bool = false) {
        cancellation.cancel()
        let cancel = CleanupCancellation()
        cancellation = cancel
        generation += 1
        let gen = generation
        phase = .scanning
        progress = nil
        isConfirming = false
        if !keepReport { report = nil }
        let env = Self.environment()
        let throttle = CleanupProgressThrottle()
        let session = self
        Task.detached(priority: .userInitiated) {
            let res = CleanupEngine.scan(environment: env, cancellation: cancel) { p in
                guard throttle.shouldEmit() else { return }
                Task { @MainActor in
                    if session.generation == gen && session.phase == .scanning { session.progress = p }
                }
            }
            await MainActor.run {
                guard session.generation == gen else { return }
                session.result = res
                session.selected = Set(res.allItems.filter { $0.preselected }.map { $0.id })
                session.phase = .results
            }
        }
    }

    func clean(onFinished: @escaping @MainActor @Sendable () -> Void) {
        let items = selectedItems
        guard !items.isEmpty, phase == .results else { return }
        cancellation.cancel()
        let cancel = CleanupCancellation()
        cancellation = cancel
        phase = .cleaning
        progress = nil
        isConfirming = false
        let env = Self.environment()
        let toTrash = moveToTrash
        let throttle = CleanupProgressThrottle()
        let session = self
        Task.detached(priority: .userInitiated) {
            let rep = CleanupEngine.delete(items: items, environment: env, moveToTrash: toTrash, cancellation: cancel) { p in
                guard throttle.shouldEmit() else { return }
                Task { @MainActor in
                    if session.phase == .cleaning { session.progress = p }
                }
            }
            await MainActor.run {
                session.report = rep
                onFinished()
                session.scan(keepReport: true)
            }
        }
    }

    // MARK: Selection

    var allItems: [CleanupItem] { result?.allItems ?? [] }
    var selectedItems: [CleanupItem] { allItems.filter { selected.contains($0.id) } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.sizeBytes } }

    func state(of items: [CleanupItem]) -> CleanupCheckState {
        var on = 0
        for item in items where selected.contains(item.id) { on += 1 }
        if on == 0 { return .off }
        return on == items.count ? .on : .mixed
    }

    func toggle(_ items: [CleanupItem]) {
        if state(of: items) == .on {
            for item in items { selected.remove(item.id) }
        } else {
            for item in items { selected.insert(item.id) }
        }
    }

    func items(of category: CleanupCategoryResult) -> [CleanupItem] {
        category.groups.flatMap { $0.items }
    }

    func selectRecommended() {
        selected = Set(allItems.filter { $0.preselected }.map { $0.id })
    }

    func risk(of item: CleanupItem) -> CleanupRisk {
        guard let result else { return .safe }
        for category in result.categories {
            for group in category.groups where group.rule.id == item.ruleID { return group.rule.risk }
        }
        return .safe
    }

    var rows: [CleanupRow] {
        guard let result else { return [] }
        var rows: [CleanupRow] = []
        for category in result.categories {
            rows.append(.category(category))
            if collapsedCategories.contains(category.id) { continue }
            for group in category.groups {
                rows.append(.group(group))
                if expandedGroups.contains(group.id) {
                    for item in group.items { rows.append(.item(item)) }
                }
            }
        }
        return rows
    }
}

/// Square three-state checkbox (on / off / partly selected).
struct CleanupCheckbox: View {
    let state: CleanupCheckState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Rectangle().fill(state == .off ? Color(nsColor: .textBackgroundColor) : Color.accentColor)
                Rectangle().stroke(state == .off ? Color(nsColor: .tertiaryLabelColor) : Color.accentColor, lineWidth: 1)
                if state == .on {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundColor(.white)
                } else if state == .mixed {
                    Rectangle().fill(Color.white).frame(width: 7, height: 2)
                }
            }
            .frame(width: 13, height: 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct CleanupSheetView: View {
    @ObservedObject var viewModel: CommanderViewModel
    @StateObject private var session = CleanupSession()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private func size(_ bytes: Int64) -> String { FileItem.formatByteCount(bytes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !FullDiskAccessHelper.hasFullDiskAccess() {
                fullDiskAccessBanner
            }
            if let report = session.report {
                reportBanner(report)
            }
            content
            footer
        }
        .padding(18)
        .frame(width: 920, height: 600)
        .onAppear { session.scan() }
        .onDisappear { session.cancel() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .bold))
            Text("Cleanup")
                .font(.headline)
            Text("Trash, caches, logs and leftovers. Nothing is deleted until you confirm.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            if let result = session.result, session.phase != .scanning {
                Text("Found " + size(result.totalBytes))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
            }
        }
    }

    private var fullDiskAccessBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield.fill").foregroundColor(.orange)
            Text("Without Full Disk Access macOS hides the Trash, Safari and sandboxed app caches, so they are missing from this list.")
                .font(.system(size: 11))
            Spacer()
            Button("Grant Full Disk Access…") {
                session.cancel()
                viewModel.activeSheet = .fullDiskAccess
            }
        }
        .padding(8)
        .background(Rectangle().fill(Color.orange.opacity(0.12)))
        .overlay(Rectangle().stroke(Color.orange.opacity(0.5), lineWidth: 1))
    }

    private func reportBanner(_ report: CleanupDeleteReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: report.failures.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(report.failures.isEmpty ? .green : .orange)
                Text(reportSummary(report))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Dismiss") { session.report = nil }
            }
            if !report.failures.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(report.failures.prefix(100)) { failure in
                            Text(failure.reason)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(failure.path)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: min(70, CGFloat(report.failures.count) * 15 + 4))
            }
        }
        .padding(8)
        .background(Rectangle().fill(Color.primary.opacity(0.05)))
        .overlay(Rectangle().stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }

    private func reportSummary(_ report: CleanupDeleteReport) -> String {
        var text = session.moveToTrash && report.freedBytes == 0
            ? "Moved \(report.deletedPaths.count) item(s) to the Trash."
            : "Removed \(report.deletedPaths.count) item(s), freed \(size(report.freedBytes))."
        if !report.failures.isEmpty {
            text += " \(report.failures.count) item(s) could not be removed completely (in use or protected by macOS):"
        }
        if report.wasCancelled { text += " Stopped early." }
        return text
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .scanning:
            progressPane(title: "Scanning…", showsFraction: true)
        case .cleaning:
            progressPane(title: session.moveToTrash ? "Moving to the Trash…" : "Deleting…", showsFraction: true)
        case .results:
            if session.allItems.isEmpty {
                emptyPane
            } else {
                resultList
            }
        }
    }

    private func progressPane(title: String, showsFraction: Bool) -> some View {
        let progress = session.progress
        let fraction: Double = {
            guard let progress, progress.totalSteps > 0 else { return 0 }
            return Double(progress.completedSteps) / Double(progress.totalSteps)
        }()
        return VStack(spacing: 12) {
            Spacer()
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            SquareProgressBar(fraction: fraction)
                .frame(width: 520)
            Text(progress?.stepTitle ?? " ")
                .font(.system(size: 12, weight: .medium))
            Text(progress?.currentPath ?? " ")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 760)
            Text(progressCounter(progress))
                .font(.system(size: 12, design: .monospaced))
            Button("Stop") { session.cancel() }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(Rectangle().stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }

    private func progressCounter(_ progress: CleanupProgress?) -> String {
        guard let progress else { return " " }
        let verb = session.phase == .cleaning ? "freed" : "found"
        return "\(progress.itemsSoFar) item(s), \(size(progress.bytesSoFar)) \(verb)"
    }

    private var emptyPane: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 30))
                .foregroundColor(.green)
            Text(session.result?.wasCancelled == true ? "Scan stopped before anything was found." : "Nothing to clean up.")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(Rectangle().stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }

    private var resultList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Category / item")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Last changed")
                    .frame(width: 110, alignment: .trailing)
                Text("Size")
                    .frame(width: 90, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.15))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(session.rows) { row in
                        rowView(row)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(Rectangle().stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }

    @ViewBuilder
    private func rowView(_ row: CleanupRow) -> some View {
        switch row {
        case .category(let category): categoryRow(category)
        case .group(let group): groupRow(group)
        case .item(let item): itemRow(item)
        }
    }

    private func chevron(open: Bool) -> some View {
        Image(systemName: open ? "chevron.down" : "chevron.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.secondary)
            .frame(width: 12)
    }

    private func categoryRow(_ category: CleanupCategoryResult) -> some View {
        let items = session.items(of: category)
        let isOpen = !session.collapsedCategories.contains(category.id)
        return HStack(spacing: 7) {
            CleanupCheckbox(state: session.state(of: items)) { session.toggle(items) }
            HStack(spacing: 7) {
                chevron(open: isOpen)
                Image(systemName: category.category.symbolName)
                    .font(.system(size: 12))
                    .frame(width: 18)
                Text(category.category.title)
                    .font(.system(size: 12.5, weight: .bold))
                Text("\(category.itemCount) item(s)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Text(size(category.totalBytes))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .frame(width: 90, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isOpen { session.collapsedCategories.insert(category.id) } else { session.collapsedCategories.remove(category.id) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.07))
        .overlay(Divider(), alignment: .bottom)
    }

    private func groupRow(_ group: CleanupGroupResult) -> some View {
        let isOpen = session.expandedGroups.contains(group.id)
        return HStack(alignment: .top, spacing: 7) {
            CleanupCheckbox(state: session.state(of: group.items)) { session.toggle(group.items) }
                .padding(.top, 1)
            HStack(alignment: .top, spacing: 7) {
                chevron(open: isOpen)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(group.rule.title)
                            .font(.system(size: 12, weight: .semibold))
                        if group.rule.risk == .caution {
                            badge("review first", color: .orange)
                        }
                        if group.items.contains(where: { $0.ownerRunning }) {
                            badge("app is running", color: .red)
                        }
                        Text("\(group.items.count) item(s)")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                    }
                    Text(group.rule.detail)
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(size(group.totalBytes))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 90, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isOpen { session.expandedGroups.remove(group.id) } else { session.expandedGroups.insert(group.id) }
            }
        }
        .padding(.leading, 30)
        .padding(.trailing, 10)
        .padding(.vertical, 5)
        .overlay(Divider(), alignment: .bottom)
    }

    private func itemRow(_ item: CleanupItem) -> some View {
        HStack(spacing: 7) {
            CleanupCheckbox(state: session.selected.contains(item.id) ? .on : .off) { session.toggle([item]) }
            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                .font(.system(size: 10.5))
                .foregroundColor(item.isDirectory ? .yellow : .blue)
                .frame(width: 16)
            Text(item.displayName)
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            if item.ownerRunning {
                badge("running", color: .red)
            }
            Spacer(minLength: 8)
            Button("Show") { reveal(item) }
                .controlSize(.small)
            Text(item.newestModification.map { Self.dateFormatter.string(from: $0) } ?? "")
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .frame(width: 110, alignment: .trailing)
            Text(size(item.sizeBytes))
                .font(.system(size: 11.5, design: .monospaced))
                .frame(width: 90, alignment: .trailing)
        }
        .padding(.leading, 62)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
        .help(item.path)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Rectangle().fill(color.opacity(0.18)))
            .overlay(Rectangle().stroke(color.opacity(0.6), lineWidth: 0.8))
    }

    /// Opens the item's folder in the active panel so it can be inspected before deleting.
    private func reveal(_ item: CleanupItem) {
        let parent = (item.path as NSString).deletingLastPathComponent
        let name = (item.path as NSString).lastPathComponent
        session.cancel()
        if !viewModel.showHiddenFiles { viewModel.showHiddenFiles = true }
        viewModel.activePanel.navigateTo(path: parent, selectingChildNamed: name)
        CommanderDialog.close(viewModel)
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        if session.isConfirming {
            confirmBar
        } else {
            actionBar
        }
    }

    private var actionBar: some View {
        let count = session.selectedItems.count
        let busy = session.phase != .results
        return HStack(spacing: 10) {
            Button("Rescan") { session.scan() }
                .disabled(session.phase == .cleaning)
            Button("Select recommended") { session.selectRecommended() }
                .disabled(busy)
            Button("Select none") { session.selected = [] }
                .disabled(busy)
            Toggle("Move to Trash instead of deleting", isOn: $session.moveToTrash)
                .font(.system(size: 11))
                .disabled(busy)
                .help("Undoable, but frees no space until the Trash is emptied. Items already in the Trash are always deleted.")
            Spacer()
            Text(busy ? "" : "Selected: \(count) item(s), \(size(session.selectedBytes))")
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
            Button("Close") { CommanderDialog.close(viewModel) }
                .keyboardShortcut(.cancelAction)
            Button("Clean \(size(session.selectedBytes))…") { session.isConfirming = true }
                .buttonStyle(SquareProminentButtonStyle())
                .disabled(busy || count == 0)
        }
    }

    private var confirmBar: some View {
        let items = session.selectedItems
        let cautionCount = items.filter { session.risk(of: $0) == .caution }.count
        let runningCount = items.filter { $0.ownerRunning }.count
        return HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text(session.moveToTrash
                     ? "Move \(items.count) item(s) (\(size(session.selectedBytes))) to the Trash?"
                     : "Permanently delete \(items.count) item(s) (\(size(session.selectedBytes)))? This cannot be undone.")
                    .font(.system(size: 12, weight: .bold))
                if cautionCount > 0 || runningCount > 0 {
                    Text(confirmWarning(caution: cautionCount, running: runningCount))
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                }
            }
            Spacer()
            Button("Cancel") { session.isConfirming = false }
                .keyboardShortcut(.cancelAction)
            Button(session.moveToTrash ? "Move to Trash" : "Delete") {
                session.clean {
                    viewModel.leftPanel.reload()
                    viewModel.rightPanel.reload()
                }
            }
            .buttonStyle(SquareProminentButtonStyle())
        }
        .padding(8)
        .background(Rectangle().fill(Color.red.opacity(0.08)))
        .overlay(Rectangle().stroke(Color.red.opacity(0.5), lineWidth: 1))
    }

    private func confirmWarning(caution: Int, running: Int) -> String {
        var parts: [String] = []
        if caution > 0 { parts.append("\(caution) item(s) are marked \"review first\" and are not regenerated automatically or are slow to restore") }
        if running > 0 { parts.append("\(running) item(s) belong to an app that is running: quit it first") }
        return parts.joined(separator: "; ") + "."
    }
}

// MARK: - Empty Trash

struct EmptyTrashSheetView: View {
    @ObservedObject var viewModel: CommanderViewModel
    @State private var summary: TrashSummary? = nil
    @State private var isWorking = false
    @State private var failures: [CleanupFailure] = []
    @State private var message: String = ""
    @State private var cancellation = CleanupCancellation()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "trash")
                    .font(.system(size: 22))
                    .foregroundColor(.red)
                Text("Empty Trash")
                    .font(.system(size: 14, weight: .bold))
            }
            Text(question)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !failures.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(failures.prefix(6)) { failure in
                        Text(failure.reason)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            HStack {
                if summary?.homeTrashUnreadable == true {
                    Button("Grant Full Disk Access…") { viewModel.activeSheet = .fullDiskAccess }
                    Button("Empty with Finder") { emptyWithFinder() }
                        .disabled(isWorking)
                }
                Spacer()
                Button((summary?.itemCount ?? 1) == 0 && summary?.homeTrashUnreadable != true ? "Close" : "Cancel (Esc)") {
                    cancellation.cancel()
                    CommanderDialog.close(viewModel)
                }
                .keyboardShortcut(.cancelAction)
                Button(isWorking ? "Emptying…" : "Empty Trash (Enter)") { empty() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(SquareProminentButtonStyle())
                    .disabled(isWorking || (summary?.itemCount ?? 0) == 0)
            }
        }
        .padding(18)
        .frame(width: 460)
        .onAppear(perform: load)
    }

    private var question: String {
        guard let summary else { return "Looking into the Trash…" }
        if summary.itemCount == 0 {
            return summary.homeTrashUnreadable
                ? "macOS does not let CZ.commander look into the Trash without Full Disk Access. Grant it, or let Finder empty the Trash."
                : "The Trash is empty."
        }
        var text = "Permanently delete the \(summary.itemCount) item(s) in the Trash (\(FileItem.formatByteCount(summary.sizeBytes)))? This cannot be undone."
        if summary.homeTrashUnreadable {
            text += "\nOnly the Trash of other drives is visible without Full Disk Access."
        }
        return text
    }

    private func load() {
        let env = CleanupSession.environment()
        Task.detached(priority: .userInitiated) {
            let result = CleanupEngine.trashSummary(environment: env)
            await MainActor.run { summary = result }
        }
    }

    private func finish(_ text: String) {
        viewModel.leftPanel.reload()
        viewModel.rightPanel.reload()
        viewModel.statusBannerMessage = text
        CommanderDialog.close(viewModel)
    }

    private func empty() {
        guard !isWorking else { return }
        isWorking = true
        message = ""
        let env = CleanupSession.environment()
        let cancel = cancellation
        Task.detached(priority: .userInitiated) {
            let report = CleanupEngine.emptyTrash(environment: env, cancellation: cancel)
            let after = CleanupEngine.trashSummary(environment: env)
            await MainActor.run {
                isWorking = false
                let freed = FileItem.formatByteCount(report.freedBytes)
                if report.failures.isEmpty {
                    finish("Trash emptied: \(report.deletedPaths.count) item(s), \(freed) freed")
                } else {
                    summary = after
                    failures = report.failures
                    message = "Freed \(freed). \(report.failures.count) item(s) could not be deleted (in use or protected by macOS):"
                    viewModel.leftPanel.reload()
                    viewModel.rightPanel.reload()
                }
            }
        }
    }

    /// Fallback without Full Disk Access: Finder empties every Trash (macOS asks once whether
    /// CZ.commander may control Finder).
    private func emptyWithFinder() {
        guard !isWorking else { return }
        isWorking = true
        message = ""
        Task.detached(priority: .userInitiated) {
            let error = CleanupEngine.emptyTrashViaFinder()
            await MainActor.run {
                isWorking = false
                if let error {
                    message = "Finder could not empty the Trash: \(error)"
                } else {
                    finish("Trash emptied by Finder")
                }
            }
        }
    }
}
