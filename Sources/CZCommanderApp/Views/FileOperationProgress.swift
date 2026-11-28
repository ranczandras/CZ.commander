import SwiftUI
import AppKit
import CZCommanderCore

// Total Commander style progress for copy (F5), move (F6) and unpack (Alt+F9): what is being
// copied from where to where, a bar for the current file and one for the whole job, speed,
// elapsed and remaining time, Pause / Background / Cancel. Jobs run one after the other on a
// background thread; "Background" hides the dialog and a toolbar indicator brings it back.

@MainActor
final class FileOperationManager: ObservableObject {
    static let shared = FileOperationManager()

    enum Kind {
        case copy(sources: [String], destination: String, options: FileOperationOptions)
        case move(sources: [String], destination: String, options: FileOperationOptions)
        case unpack(archives: [String], destination: String, alwaysFolder: Bool)
        case extract(archive: String, entries: [String], destination: String)
    }

    struct Job: Identifiable {
        let id = UUID()
        let kind: Kind
        let title: String
    }

    enum Outcome: Equatable {
        case running
        case finished
        case cancelled
        case failed(String)
    }

    @Published private(set) var current: Job? = nil
    @Published private(set) var progress = FileOperationProgress()
    @Published private(set) var outcome: Outcome = .running
    @Published private(set) var isPaused = false
    @Published private(set) var queued: [Job] = []

    private var control = TransferControl()
    weak var viewModel: CommanderViewModel?

    var isBusy: Bool { current != nil }

    // MARK: Start

    func copy(_ sources: [String], to destination: String, options: FileOperationOptions = FileOperationOptions(),
              background: Bool = false) {
        enqueue(Job(kind: .copy(sources: sources, destination: destination, options: options),
                    title: "Copy " + Self.countText(sources) + " to " + Self.short(destination)), background: background)
    }

    func move(_ sources: [String], to destination: String, options: FileOperationOptions = FileOperationOptions(),
              background: Bool = false) {
        enqueue(Job(kind: .move(sources: sources, destination: destination, options: options),
                    title: "Move " + Self.countText(sources) + " to " + Self.short(destination)), background: background)
    }

    func unpack(_ archives: [String], to destination: String, alwaysFolder: Bool) {
        enqueue(Job(kind: .unpack(archives: archives, destination: destination, alwaysFolder: alwaysFolder),
                    title: "Unpack " + Self.countText(archives) + " to " + Self.short(destination)), background: false)
    }

    func extract(from archive: String, entries: [String], to destination: String) {
        enqueue(Job(kind: .extract(archive: archive, entries: entries, destination: destination),
                    title: "Unpack \(entries.count) item(s) to " + Self.short(destination)), background: false)
    }

    private func enqueue(_ job: Job, background: Bool) {
        if current == nil {
            run(job, showDialog: !background)
        } else {
            queued.append(job)
            if !background { showDialog() }
        }
    }

    // MARK: Controls

    func togglePause() {
        guard current != nil, outcome == .running else { return }
        if isPaused { control.resume() } else { control.pause() }
        isPaused.toggle()
    }

    func cancel() {
        control.cancel()
        isPaused = false
    }

    func cancelQueued(_ id: UUID) {
        queued.removeAll { $0.id == id }
    }

    func showDialog() {
        guard let vm = viewModel ?? Optional(CommanderViewModel.shared) else { return }
        MainWindowController.show()
        vm.activeSheet = .fileOperationProgress
    }

    func hideDialog() {
        guard let vm = viewModel ?? Optional(CommanderViewModel.shared) else { return }
        if case .fileOperationProgress = vm.activeSheet {
            CommanderDialog.close(vm)
        }
    }

    /// Closes the dialog after a failed job was looked at.
    func dismissResult() {
        if current == nil { outcome = .running }
        hideDialog()
    }

    // MARK: Run

    private func run(_ job: Job, showDialog show: Bool) {
        current = job
        outcome = .running
        isPaused = false
        progress = FileOperationProgress()
        progress.isScanning = true
        control = TransferControl()
        let control = self.control
        if show { showDialog() }

        let report: @Sendable (FileOperationProgress) -> Void = { p in
            DispatchQueue.main.async {
                let m = FileOperationManager.shared
                if m.current?.id == job.id { m.progress = p }
            }
        }
        let kind = job.kind
        Task.detached(priority: .userInitiated) {
            var result: Outcome = .finished
            do {
                switch kind {
                case .copy(let sources, let destination, let options):
                    try TransferEngine.copyOrMove(sources: sources, to: destination, isMove: false, options: options,
                                                  control: control, progress: report)
                case .move(let sources, let destination, let options):
                    try TransferEngine.copyOrMove(sources: sources, to: destination, isMove: true, options: options,
                                                  control: control, progress: report)
                case .unpack(let archives, let destination, let alwaysFolder):
                    for archive in archives {
                        try ArchiveEngine.unpackArchive(archivePath: archive, toDirectory: destination,
                                                        unpackEachToSeparateSubdir: alwaysFolder,
                                                        control: control, progress: report)
                    }
                case .extract(let archive, let entries, let destination):
                    try ArchiveEngine.unpackArchive(archivePath: archive, toDirectory: destination, specificEntries: entries,
                                                    control: control, progress: report)
                }
            } catch is TransferCancelledError {
                result = .cancelled
            } catch {
                result = .failed(error.localizedDescription)
            }
            let final = result
            await MainActor.run { FileOperationManager.shared.finish(job, outcome: final) }
        }
    }

    private func finish(_ job: Job, outcome result: Outcome) {
        guard current?.id == job.id else { return }
        let vm = viewModel ?? CommanderViewModel.shared
        vm.activePanel.activeTab.selectedItemIDs.removeAll()
        vm.leftPanel.reload()
        vm.rightPanel.reload()
        current = nil
        isPaused = false
        outcome = result
        switch result {
        case .failed:
            // Keep the dialog (or reopen it) so the error is seen.
            showDialog()
            return
        case .cancelled:
            vm.statusBannerMessage = job.title + ": cancelled"
        case .finished, .running:
            vm.statusBannerMessage = job.title + ": done"
        }
        if let next = queued.first {
            queued.removeFirst()
            let dialogOpen: Bool
            if case .fileOperationProgress = vm.activeSheet { dialogOpen = true } else { dialogOpen = false }
            run(next, showDialog: dialogOpen)
        } else {
            outcome = .running
            hideDialog()
        }
    }

    // MARK: Text helpers

    static func countText(_ paths: [String]) -> String {
        paths.count == 1 ? "\"" + (paths[0] as NSString).lastPathComponent + "\"" : "\(paths.count) items"
    }

    static func short(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite else { return "--:--" }
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        bytesPerSecond > 0 ? FileItem.formatByteCount(Int64(bytesPerSecond)) + "/s" : "–"
    }
}

// MARK: - Dialog

struct FileOperationProgressView: View {
    @ObservedObject var viewModel: CommanderViewModel
    @ObservedObject private var manager = FileOperationManager.shared

    private func size(_ b: Int64) -> String { FileItem.formatByteCount(b) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .bold))
                Text(manager.current?.title ?? lastTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if manager.isPaused {
                    Text("PAUSED")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay(Rectangle().stroke(Color.orange, lineWidth: 1))
                }
            }

            if case .failed(let message) = manager.outcome, manager.current == nil {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                    Text(message)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Rectangle().fill(Color.red.opacity(0.08)))
                .overlay(Rectangle().stroke(Color.red.opacity(0.5), lineWidth: 1))
                HStack {
                    Spacer()
                    Button("Close") { manager.dismissResult() }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                details
                buttons
            }

            if !manager.queued.isEmpty {
                Divider()
                Text("Queued (\(manager.queued.count))")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(.secondary)
                ForEach(manager.queued) { job in
                    HStack {
                        Text(job.title).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { manager.cancelQueued(job.id) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain)
                            .help("Remove from the queue")
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 600)
    }

    @State private var lastTitle = ""

    private var icon: String {
        switch manager.current?.kind {
        case .move: return "arrow.right.doc.on.clipboard"
        case .unpack, .extract: return "shippingbox.and.arrow.backward.fill"
        default: return "doc.on.doc.fill"
        }
    }

    private var details: some View {
        let p = manager.progress
        return VStack(alignment: .leading, spacing: 8) {
            if p.isScanning {
                Text("Counting files… \(p.totalFiles) file(s), \(size(p.totalBytes))")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            pathRow("From:", p.currentSourcePath.isEmpty ? p.currentFileName : p.currentSourcePath)
            pathRow("To:", p.currentDestinationPath)

            if p.currentFileTotal > 0 {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(p.currentFileName).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(String(format: "%.0f%%", p.currentFileFraction * 100) + "   " + size(p.currentFileBytes) + " / " + size(p.currentFileTotal))
                            .font(.system(size: 11, design: .monospaced))
                    }
                    SquareProgressBar(fraction: p.currentFileFraction)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Total").font(.system(size: 11, weight: .semibold))
                    Text("file \(min(p.processedFiles + (p.processedFiles < p.totalFiles ? 1 : 0), max(p.totalFiles, 1))) of \(p.totalFiles)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.1f%%", p.fractionCompleted * 100) + "   " + size(p.processedBytes) + " / " + size(p.totalBytes))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
                SquareProgressBar(fraction: p.fractionCompleted)
                    .frame(height: 14)
            }

            HStack(spacing: 18) {
                stat("Speed", manager.isPaused ? "paused" : FileOperationManager.speed(p.bytesPerSecond))
                stat("Elapsed", FileOperationManager.duration(p.elapsedSeconds))
                stat("Remaining", manager.isPaused ? "--:--" : FileOperationManager.duration(p.remainingSeconds))
            }
        }
        .onAppear { lastTitle = manager.current?.title ?? lastTitle }
    }

    private func pathRow(_ label: String, _ path: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 42, alignment: .leading)
            Text(path.isEmpty ? "–" : path)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
                .help(path)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9.5)).foregroundColor(.secondary)
            Text(value).font(.system(size: 13, weight: .semibold, design: .monospaced))
        }
    }

    private var buttons: some View {
        HStack {
            Button("Background") { manager.hideDialog() }
                .help("Hide this window; the job keeps running (the toolbar shows its progress)")
            Spacer()
            Button(manager.isPaused ? "Resume" : "Pause") { manager.togglePause() }
                .disabled(manager.current == nil)
            Button("Cancel") { manager.cancel() }
                .keyboardShortcut(.cancelAction)
                .disabled(manager.current == nil)
        }
    }
}

/// Small toolbar indicator while a job runs in the background; click to show the dialog.
struct FileOperationIndicator: View {
    @ObservedObject private var manager = FileOperationManager.shared

    var body: some View {
        if let job = manager.current {
            Button {
                manager.showDialog()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: manager.isPaused ? "pause.fill" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .bold))
                    Text(String(format: "%.0f%%", manager.progress.fractionCompleted * 100))
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    SquareProgressBar(fraction: manager.progress.fractionCompleted)
                        .frame(width: 50)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(job.title + (manager.queued.isEmpty ? "" : " (+\(manager.queued.count) queued)"))
        }
    }
}
