import SwiftUI
import AppKit
import CZCommanderCore

// YouTube downloader window. The queue lives in `YouTubeDownloadManager.shared`, so closing
// the window does not stop running downloads.

struct YouTubeJob: Identifiable, Equatable {
    enum State: Equatable {
        case queued
        case preparing(String)
        case downloading
        case done
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let link: YouTubeLink
    let kind: YouTubeMediaKind
    var state: State = .queued
    var title: String? = nil
    var itemIndex: Int? = nil
    var itemCount: Int? = nil
    var fraction: Double? = nil
    var speed: Double? = nil
    var eta: Int? = nil
    var files: [String] = []
    var errors: [String] = []

    var isActive: Bool {
        switch state {
        case .queued, .preparing, .downloading: return true
        default: return false
        }
    }
}

/// Collects a child process' output into lines without blocking the main thread.
private final class YouTubeLineReader: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let nl = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if !lineData.isEmpty { lines.append(String(decoding: lineData, as: UTF8.self)) }
        }
        lock.unlock()
        lines.forEach(onLine)
    }

    func flush() {
        lock.lock()
        let rest = buffer
        buffer.removeAll()
        lock.unlock()
        if !rest.isEmpty { onLine(String(decoding: rest, as: UTF8.self)) }
    }
}

@MainActor
final class YouTubeDownloadManager: ObservableObject {
    static let shared = YouTubeDownloadManager()

    @Published private(set) var jobs: [YouTubeJob] = []
    @Published private(set) var toolchain: YouTubeToolchain
    @Published private(set) var toolStatus: String? = nil
    @Published var kind: YouTubeMediaKind {
        didSet { UserDefaults.standard.set(kind.rawValue, forKey: "YouTubeDownloaderKind") }
    }
    @Published var login: YouTubeLoginBrowser {
        didSet { UserDefaults.standard.set(login.rawValue, forKey: "YouTubeDownloaderLogin") }
    }

    /// "Not logged in" plus the browsers installed on this Mac.
    var loginChoices: [YouTubeLoginBrowser] {
        YouTubeLoginBrowser.allCases.filter { browser in
            guard let id = browser.bundleIdentifier else { return true }
            return browser == login || NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
        }
    }

    /// Called with the output folder whenever a download finished (panels refresh).
    var onFilesChanged: ((String) -> Void)?

    private var runningJobID: UUID? = nil
    private var process: Process? = nil
    private var lastProgressUpdate = Date.distantPast

    private init() {
        toolchain = YouTubeToolchain()
        let saved = UserDefaults.standard.string(forKey: "YouTubeDownloaderKind")
        kind = saved.flatMap(YouTubeMediaKind.init(rawValue:)) ?? .video
        login = UserDefaults.standard.string(forKey: "YouTubeDownloaderLogin").flatMap(YouTubeLoginBrowser.init(rawValue:)) ?? .none
        refreshToolchain()
        // yt-dlp would keep running as an orphan after the app quits.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                YouTubeDownloadManager.shared.process?.terminate()
            }
        }
    }

    var outputDirectory: String { YouTubeToolchain.downloadsDirectory.path }
    var hasActiveJobs: Bool { jobs.contains { $0.isActive } }

    func refreshToolchain() {
        Task.detached(priority: .utility) {
            let chain = YouTubeToolchain.locate()
            await MainActor.run { YouTubeDownloadManager.shared.toolchain = chain }
        }
    }

    /// Adds every link found in `text`; returns how many were added.
    @discardableResult
    func enqueue(text: String) -> Int {
        let links = YouTubeLinkParser.links(in: text)
        for link in links {
            jobs.append(YouTubeJob(link: link, kind: kind))
        }
        startNextIfIdle()
        return links.count
    }

    func cancel(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        if runningJobID == id, let p = process {
            jobs[i].state = .cancelled
            p.interrupt()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if p.isRunning { p.terminate() } }
        } else if jobs[i].isActive {
            jobs[i].state = .cancelled
        }
    }

    func retry(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), !jobs[i].isActive else { return }
        let old = jobs[i]
        jobs[i] = YouTubeJob(link: old.link, kind: old.kind)
        startNextIfIdle()
    }

    func remove(_ id: UUID) {
        jobs.removeAll { $0.id == id && !$0.isActive }
    }

    func clearFinished() {
        jobs.removeAll { !$0.isActive }
    }

    func cancelAll() {
        for job in jobs where job.isActive { cancel(job.id) }
    }

    // MARK: Running

    private func update(_ id: UUID, _ change: (inout YouTubeJob) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
    }

    private func startNextIfIdle() {
        guard runningJobID == nil, let next = jobs.first(where: { $0.state == .queued }) else { return }
        runningJobID = next.id
        Task { await self.run(next.id) }
    }

    private func finish(_ id: UUID) {
        if runningJobID == id {
            runningJobID = nil
            process = nil
        }
        onFilesChanged?(outputDirectory)
        startNextIfIdle()
    }

    private func isCancelled(_ id: UUID) -> Bool {
        jobs.first(where: { $0.id == id })?.state == .cancelled
    }

    private func run(_ id: UUID) async {
        // 1. Tools
        var chain = YouTubeToolchain.locate()
        toolchain = chain
        if !chain.isComplete {
            update(id) { $0.state = .preparing("Installing " + chain.missing.joined(separator: ", ") + " (one time)…") }
            do {
                try await YouTubeToolInstaller.install(YouTubeToolInstaller.sources(for: chain)) { text in
                    Task { @MainActor in
                        YouTubeDownloadManager.shared.toolStatus = text
                        YouTubeDownloadManager.shared.update(id) { job in
                            if case .preparing = job.state { job.state = .preparing(text) }
                        }
                    }
                }
            } catch {
                toolStatus = error.localizedDescription
                update(id) { $0.state = .failed("Tools could not be installed: " + error.localizedDescription) }
                finish(id)
                return
            }
            chain = YouTubeToolchain.locate()
            toolchain = chain
            guard chain.isComplete else {
                update(id) { $0.state = .failed("Missing tools: " + chain.missing.joined(separator: ", ")) }
                finish(id)
                return
            }
        }
        if isCancelled(id) { finish(id); return }

        // 2. Keep our own yt-dlp current (YouTube changes break old versions).
        if let yt = chain.ytDlp, YouTubeToolInstaller.shouldSelfUpdate(ytDlp: yt) {
            update(id) { $0.state = .preparing("Checking for yt-dlp updates…") }
            await Task.detached(priority: .utility) {
                _ = YouTubeProcess.capture(yt, ["-U"], timeout: 90)
                YouTubeToolInstaller.markSelfUpdateChecked()
            }.value
            if isCancelled(id) { finish(id); return }
        }

        // 3. Download
        guard let job = jobs.first(where: { $0.id == id }), let ytDlp = chain.ytDlp else { finish(id); return }
        do {
            try FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
        } catch {
            update(id) { $0.state = .failed("Cannot create \(outputDirectory): \(error.localizedDescription)") }
            finish(id)
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: ytDlp)
        p.arguments = YouTubeCommand.arguments(for: job.link, kind: job.kind, outputDirectory: outputDirectory, toolchain: chain, login: login)
        p.environment = YouTubeProcess.environment(toolchain: chain)
        p.currentDirectoryURL = URL(fileURLWithPath: outputDirectory)
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        let reader = YouTubeLineReader { line in
            let event = YouTubeOutputParser.parse(line)
            DispatchQueue.main.async { YouTubeDownloadManager.shared.handle(event, for: id) }
        }
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                reader.append(data)
            }
        }
        p.terminationHandler = { proc in
            let status = proc.terminationStatus
            // Drain whatever is left before reporting the end.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) {
                pipe.fileHandleForReading.readabilityHandler = nil
                if let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty { reader.append(rest) }
                reader.flush()
                DispatchQueue.main.async { YouTubeDownloadManager.shared.processEnded(id, status: status) }
            }
        }

        update(id) { $0.state = .downloading }
        do {
            try p.run()
            process = p
        } catch {
            update(id) { $0.state = .failed("yt-dlp could not start: \(error.localizedDescription)") }
            finish(id)
        }
    }

    private func handle(_ event: YouTubeOutputEvent, for id: UUID) {
        switch event {
        case .progress(let downloaded, let total, let speed, let eta):
            let now = Date()
            guard now.timeIntervalSince(lastProgressUpdate) > 0.15 || (downloaded != nil && downloaded == total) else { return }
            lastProgressUpdate = now
            update(id) { job in
                if let d = downloaded, let t = total, t > 0 { job.fraction = min(1, Double(d) / Double(t)) }
                job.speed = speed
                job.eta = eta
            }
        case .item(let index, let count, let title):
            update(id) { job in
                job.title = title.isEmpty ? job.title : title
                job.itemIndex = index
                job.itemCount = count
                job.fraction = 0
            }
        case .file(let path):
            update(id) { $0.files.append(path) }
        case .error(let message):
            update(id) { $0.errors.append(message) }
        case .warning, .other:
            break
        }
    }

    private func processEnded(_ id: UUID, status: Int32) {
        update(id) { job in
            if job.state == .cancelled { return }
            job.fraction = nil
            job.speed = nil
            job.eta = nil
            if status == 0 || !job.files.isEmpty {
                job.state = .done
            } else {
                job.state = .failed(job.errors.last ?? "yt-dlp stopped with code \(status).")
            }
        }
        finish(id)
    }
}

// MARK: - Window

/// The downloader lives in its own movable, resizable window (not a modal sheet), so the
/// file panels stay usable. Closing or hiding it keeps the downloads running.
@MainActor
enum YouTubeDownloaderWindowController {
    static let id = "youtube"
    static var window: NSWindow? { AuxWindow.window(id) }

    static func show(viewModel: CommanderViewModel? = nil) {
        let vm = viewModel ?? CommanderViewModel.shared
        AuxWindow.show(id: id, title: "YouTube Downloader", size: NSSize(width: 880, height: 640),
                       minSize: NSSize(width: 720, height: 460)) {
            YouTubeDownloaderSheetView(viewModel: vm)
        }
    }

    static func hide() { AuxWindow.hide(id) }
}

/// Placed in the main window's sheet slot when `.youtubeDownloader` is requested (menu
/// command, button bar): opens the separate window instead of a modal sheet.
struct YouTubeDownloaderLauncher: View {
    @ObservedObject var viewModel: CommanderViewModel

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {
                viewModel.activeSheet = nil
                YouTubeDownloaderWindowController.show(viewModel: viewModel)
            }
    }
}

struct YouTubeDownloaderSheetView: View {
    @ObservedObject var viewModel: CommanderViewModel
    @ObservedObject private var manager = YouTubeDownloadManager.shared
    @State private var linkText = ""
    @State private var notice: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            input
            queue
            footer
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand { YouTubeDownloaderWindowController.hide() }
        .onAppear {
            manager.refreshToolchain()
            let vm = viewModel
            manager.onFilesChanged = { folder in
                for panel in [vm.leftPanel, vm.rightPanel] where panel.currentPath.hasPrefix(folder) {
                    panel.reload()
                }
            }
            if linkText.isEmpty, let clip = NSPasteboard.general.string(forType: .string),
               !YouTubeLinkParser.links(in: clip).isEmpty {
                linkText = clip
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.red)
            Text("YouTube Downloader")
                .font(.headline)
            Text("Videos and playlists in the best available quality.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            toolsLabel
        }
    }

    private var toolsLabel: some View {
        let chain = manager.toolchain
        let text: String
        if let status = manager.toolStatus, manager.hasActiveJobs, !chain.isComplete {
            text = status
        } else if chain.isComplete {
            text = "Tools ready"
        } else {
            text = "Installs " + chain.missing.joined(separator: ", ") + " on first download"
        }
        return Text(text)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundColor(.secondary)
            .help(toolsHelp(chain))
    }

    private func toolsHelp(_ chain: YouTubeToolchain) -> String {
        var lines = ["Tools folder: " + YouTubeToolchain.toolsDirectory.path]
        lines.append("yt-dlp: " + (chain.ytDlp ?? "not installed"))
        lines.append("ffmpeg: " + (chain.ffmpeg ?? "not installed"))
        lines.append("JS runtime: " + (chain.jsRuntime?.path ?? "not installed"))
        return lines.joined(separator: "\n")
    }

    // MARK: Input

    private var input: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Paste one or more links (video, playlist or channel), one per line:")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            TextEditor(text: $linkText)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Rectangle().fill(Color(nsColor: .textBackgroundColor)))
                .overlay(Rectangle().stroke(Color(nsColor: .separatorColor), lineWidth: 0.8))
                .frame(height: 74)
            HStack(spacing: 10) {
                SquarePicker("", selection: $manager.kind,
                             options: YouTubeMediaKind.allCases.map { ($0, $0.title) },
                             kind: .segmented)
                    .frame(width: 240)
                Text(manager.kind == .video
                     ? "Best resolution, video + audio merged into MP4."
                     : "Best audio, converted to MP3 (VBR ~245 kbps) with cover art.")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                Spacer()
                if let notice {
                    Text(notice)
                        .font(.system(size: 10.5))
                        .foregroundColor(.orange)
                }
                Button("Paste") {
                    if let clip = NSPasteboard.general.string(forType: .string) {
                        linkText = linkText.isEmpty ? clip : linkText + "\n" + clip
                    }
                }
                Button("Download") { startDownload() }
                    .buttonStyle(SquareProminentButtonStyle())
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Download (Cmd+Return)")
            }
            HStack(spacing: 10) {
                SquarePicker("YouTube login:", selection: $manager.login,
                             options: manager.loginChoices.map { ($0, $0.title) })
                    .font(.system(size: 11))
                    .frame(width: 240)
                    .help(loginHelp)
                Text(manager.login == .none
                     ? "Off. Turn on for bot checks, private lists and Premium quality."
                     : "Uses your YouTube login in \(manager.login.title) (Premium quality if the account has it).")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .help(loginHelp)
                Spacer()
                if manager.login == .safari && !FullDiskAccessHelper.hasFullDiskAccess() {
                    Button("Safari login needs Full Disk Access…") { viewModel.activeSheet = .fullDiskAccess }
                        .foregroundColor(.orange)
                }
            }
        }
    }

    private var loginHelp: String {
        """
        Uses the YouTube login of the chosen browser (no password is asked for). \
        Needed for "Sign in to confirm you're not a bot", age-restricted, members-only and private videos, \
        Watch Later / Liked lists, and YouTube Premium quality (1080p Premium, 256 kbps audio).
        Chrome-based browsers: macOS asks once for Keychain access. Safari: needs Full Disk Access.
        Google may limit accounts that download a lot; very large playlists are better without login.
        """
    }

    private func startDownload() {
        let added = manager.enqueue(text: linkText)
        if added == 0 {
            notice = "No link found."
        } else {
            notice = nil
            linkText = ""
        }
    }

    // MARK: Queue

    private var queue: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if manager.jobs.isEmpty {
                    Text("Nothing downloaded yet. Files go to " + abbreviated(manager.outputDirectory) + ".")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 60)
                }
                ForEach(manager.jobs) { job in
                    YouTubeJobRow(job: job, manager: manager, viewModel: viewModel)
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 0.8)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(Rectangle().fill(Color.primary.opacity(0.03)))
        .overlay(Rectangle().stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
            Text(abbreviated(manager.outputDirectory))
                .font(.system(size: 11, design: .monospaced))
            Button("Open in Panel") { openFolderInPanel() }
            Button("Show in Finder") {
                try? FileManager.default.createDirectory(atPath: manager.outputDirectory, withIntermediateDirectories: true)
                NSWorkspace.shared.open(URL(fileURLWithPath: manager.outputDirectory))
            }
            Spacer()
            if manager.hasActiveJobs {
                Text("Downloads keep running when this window is hidden.")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                Button("Stop All") { manager.cancelAll() }
            }
            Button("Clear Finished") { manager.clearFinished() }
                .disabled(!manager.jobs.contains { !$0.isActive })
            Button("Hide") { YouTubeDownloaderWindowController.hide() }
                .keyboardShortcut(.cancelAction)
                .help("Hide the window; downloads keep running (Cmd+Opt+Y brings it back)")
        }
    }

    private func openFolderInPanel() {
        try? FileManager.default.createDirectory(atPath: manager.outputDirectory, withIntermediateDirectories: true)
        viewModel.activePanel.navigateTo(path: manager.outputDirectory)
        MainWindowController.show()
    }

    private func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

private struct YouTubeJobRow: View {
    let job: YouTubeJob
    let manager: YouTubeDownloadManager
    let viewModel: CommanderViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: job.kind == .video ? "film" : "music.note")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(job.title ?? job.link.url)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if job.link.isPlaylist {
                        Text("PLAYLIST")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .overlay(Rectangle().stroke(Color.secondary, lineWidth: 0.8))
                    }
                    Spacer()
                    Text(job.kind.fileExtension.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                if job.title != nil {
                    Text(job.link.url)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                statusLine
                if job.state == .downloading {
                    SquareProgressBar(fraction: job.fraction ?? 0)
                }
            }
            actions
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch job.state {
        case .queued:
            label("Waiting…", color: .secondary)
        case .preparing(let text):
            label(text, color: .secondary)
        case .downloading:
            label(downloadingText, color: .primary)
        case .done:
            let failed = job.errors.count
            let text = job.files.isEmpty
                ? "Done (already downloaded)."
                : "Done: \(job.files.count) file(s)" + (failed > 0 ? ", \(failed) item(s) failed: " + (job.errors.last ?? "") : ".")
            label(text, color: failed > 0 ? .orange : .green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 2) {
                label("Failed: " + message, color: .red)
                if YouTubeOutputParser.needsLogin(message) {
                    label(manager.login == .none
                          ? "YouTube wants a login: choose your browser at \"YouTube login\" above, then Retry."
                          : "Still refused: make sure you are signed in to YouTube in \(manager.login.title), then Retry.",
                          color: .orange)
                }
            }
        case .cancelled:
            label("Stopped.", color: .secondary)
        }
    }

    private var downloadingText: String {
        var parts: [String] = []
        if let i = job.itemIndex, let n = job.itemCount, n > 1 { parts.append("Item \(i) of \(n)") }
        if let f = job.fraction { parts.append(String(format: "%.0f%%", f * 100)) }
        if let s = job.speed, s > 0 { parts.append(FileItem.formatByteCount(Int64(s)) + "/s") }
        if let e = job.eta, e > 0 { parts.append(String(format: "%d:%02d left", e / 60, e % 60)) }
        if !job.files.isEmpty { parts.append("\(job.files.count) saved") }
        return parts.isEmpty ? "Starting…" : parts.joined(separator: "  ·  ")
    }

    private func label(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundColor(color)
            .lineLimit(2)
            .help(text)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            if job.isActive {
                Button("Stop") { manager.cancel(job.id) }
            } else {
                if let last = job.files.last {
                    Button("Show") { showInPanel(last) }
                        .help("Select the file in the active panel")
                }
                if job.state != .done || !job.errors.isEmpty {
                    Button("Retry") { manager.retry(job.id) }
                }
                Button {
                    manager.remove(job.id)
                } label: {
                    Image(systemName: "xmark")
                }
                .help("Remove from the list")
            }
        }
        .font(.system(size: 11))
    }

    private func showInPanel(_ path: String) {
        let folder = (path as NSString).deletingLastPathComponent
        viewModel.activePanel.navigateTo(path: folder, selectingChildNamed: (path as NSString).lastPathComponent)
        MainWindowController.show()
    }
}
