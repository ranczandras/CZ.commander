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
        /// Dropbox -> Mac. `deleteAfter`: F6 (moves Dropbox items to Dropbox's deleted files).
        case dropboxDownload(items: [DropboxEntry], destination: String, deleteAfter: Bool, openAfter: Bool)
        /// Mac -> Dropbox. `trashAfter`: F6 (local originals go to the Trash).
        case dropboxUpload(paths: [String], destination: DropboxLocation, options: FileOperationOptions, trashAfter: Bool)
        /// Inside Dropbox, done by the server.
        case dropboxServer(items: [DropboxEntry], destination: DropboxLocation, isMove: Bool)
    }

    struct Job: Identifiable {
        let id = UUID()
        let kind: Kind
        let title: String
        /// Called on the main thread when the job ends (file promises wait for it).
        var onFinish: ((Outcome) -> Void)? = nil
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
    /// A target that exists; the job waits until `answer(_:)` is called.
    @Published private(set) var pendingConflict: TransferConflict? = nil
    /// Hand-over between the UI (writes) and the waiting transfer thread (reads).
    final class AnswerBox: @unchecked Sendable {
        let lock = NSLock()
        var value: TransferConflictDecision = .skip
        let signal = DispatchSemaphore(value: 0)
    }
    nonisolated let answerBox = AnswerBox()

    private var control = TransferControl()
    weak var viewModel: CommanderViewModel?

    var isBusy: Bool { current != nil }

    // MARK: Start

    func copy(_ sources: [String], to destination: String, options: FileOperationOptions = FileOperationOptions(overwritePolicy: .ask),
              background: Bool = false) {
        enqueue(Job(kind: .copy(sources: sources, destination: destination, options: options),
                    title: "Copy " + Self.countText(sources) + " to " + Self.short(destination)), background: background)
    }

    func move(_ sources: [String], to destination: String, options: FileOperationOptions = FileOperationOptions(overwritePolicy: .ask),
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

    func dropbox(_ kind: Kind, title: String, background: Bool = false, onFinish: ((Outcome) -> Void)? = nil) {
        enqueue(Job(kind: kind, title: title, onFinish: onFinish), background: background)
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
        if pendingConflict != nil { answer(.cancel) }
        control.cancel()
        isPaused = false
    }

    /// The user's choice in the "File exists" panel.
    func answer(_ decision: TransferConflictDecision) {
        guard pendingConflict != nil else { return }
        answerBox.lock.withLock { answerBox.value = decision }
        pendingConflict = nil
        answerBox.signal.signal()
    }

    /// Called on the transfer thread: shows the question and blocks until it is answered.
    nonisolated static func ask(_ conflict: TransferConflict, box: AnswerBox) -> TransferConflictDecision {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let m = FileOperationManager.shared
                m.pendingConflict = conflict
                m.showDialog()
            }
        }
        box.signal.wait()
        return box.lock.withLock { box.value }
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
        let box = answerBox
        control.conflictResolver = { conflict in FileOperationManager.ask(conflict, box: box) }
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
                case .dropboxDownload(let items, let destination, let deleteAfter, let openAfter):
                    let paths = try await DropboxTransfer.download(items, to: destination,
                                                                   options: FileOperationOptions(overwritePolicy: openAfter ? .overwriteAll : .ask),
                                                                   control: control, progress: report)
                    if deleteAfter {
                        for item in items { try await DropboxClient.shared.delete(item.location) }
                    }
                    if openAfter, let first = paths.first {
                        await MainActor.run { _ = NSWorkspace.shared.open(URL(fileURLWithPath: first)) }
                    }
                case .dropboxUpload(let paths, let destination, let options, let trashAfter):
                    try await DropboxTransfer.upload(paths, to: destination, options: options, control: control, progress: report)
                    if trashAfter {
                        for p in paths { try? FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil) }
                    }
                case .dropboxServer(let items, let destination, let isMove):
                    try await DropboxTransfer.copyWithinDropbox(items, to: destination, isMove: isMove, control: control, progress: report)
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
        job.onFinish?(result)
        let vm = viewModel ?? CommanderViewModel.shared
        vm.activePanel.activeTab.selectedItemIDs.removeAll()
        DropboxPanelCache.shared.invalidateAll()
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
            let p = progress
            let copied = max(0, p.processedFiles - p.skippedFiles)
            vm.statusBannerMessage = job.title + ": done – \(copied) file(s) copied"
                + (p.skippedFiles > 0 ? ", \(p.skippedFiles) skipped (already there)" : "")
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

            if let conflict = manager.pendingConflict {
                conflictPanel(conflict)
            } else if case .failed(let message) = manager.outcome, manager.current == nil {
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

    // MARK: File exists

    private func conflictPanel(_ c: TransferConflict) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                Text("File exists").font(.system(size: 13, weight: .bold))
            }
            Text(c.sourceName).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            conflictRow("Overwrite:", c.targetPath, c.targetSize, c.targetDate,
                        newer: (c.targetDate ?? .distantPast) > (c.sourceDate ?? .distantPast))
            conflictRow("With:", c.sourcePath, c.sourceSize, c.sourceDate,
                        newer: (c.sourceDate ?? .distantPast) > (c.targetDate ?? .distantPast))
            HStack(spacing: 6) {
                Button("Overwrite") { manager.answer(.overwrite) }
                    .buttonStyle(SquareProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                Button("Overwrite All") { manager.answer(.overwriteAll) }
                Button("Overwrite All Older") { manager.answer(.overwriteAllOlder) }
                    .help("Overwrite only where the target is older than the source, for all files")
                Spacer()
            }
            HStack(spacing: 6) {
                Button("Skip") { manager.answer(.skip) }
                Button("Skip All") { manager.answer(.skipAll) }
                    .help("Keep every file that already exists; copy only what is missing")
                Button("Rename") { manager.answer(.rename) }
                    .help("Keep both: the copy gets a new name")
                Button("Rename All") { manager.answer(.renameAll) }
                Spacer()
                Button("Cancel") { manager.cancel() }
            }
        }
        .padding(10)
        .background(Rectangle().fill(Color.orange.opacity(0.08)))
        .overlay(Rectangle().stroke(Color.orange.opacity(0.5), lineWidth: 1))
    }

    private static let conflictDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private func conflictRow(_ label: String, _ path: String, _ size: Int64?, _ date: Date?, newer: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label).font(.system(size: 11, weight: .semibold)).frame(width: 66, alignment: .leading)
                Text(path).font(.system(size: 10.5, design: .monospaced)).lineLimit(1).truncationMode(.head).help(path)
            }
            HStack(spacing: 10) {
                Spacer().frame(width: 66)
                Text(size.map { FileItem.formatByteCount($0) + " (\($0) bytes)" } ?? "size unknown")
                    .font(.system(size: 10.5, design: .monospaced))
                Text(date.map { Self.conflictDate.string(from: $0) } ?? "")
                    .font(.system(size: 10.5, design: .monospaced))
                if newer { Text("newer").font(.system(size: 9.5, weight: .bold)).foregroundColor(.green) }
            }
            .foregroundColor(.secondary)
        }
    }

    private var icon: String {
        switch manager.current?.kind {
        case .move: return "arrow.right.doc.on.clipboard"
        case .unpack, .extract: return "shippingbox.and.arrow.backward.fill"
        case .dropboxDownload: return "icloud.and.arrow.down"
        case .dropboxUpload: return "icloud.and.arrow.up"
        case .dropboxServer: return "icloud"
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
