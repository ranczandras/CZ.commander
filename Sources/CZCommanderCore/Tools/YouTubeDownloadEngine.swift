import Foundation
import CryptoKit

// YouTube downloader: paste links (videos or playlists), get MP4 (best video + best audio)
// or MP3 (best audio, VBR ~245 kbps) in ~/Downloads/YoutubeZ.
//
// The work is done by yt-dlp, with ffmpeg for merging / converting and a JavaScript
// runtime (deno or node) that YouTube's player needs. Tools already on the Mac are used
// when they are recent enough; otherwise the official builds are downloaded once into
// ~/Library/Application Support/CZ.commander/tools and verified with SHA-256.

public enum YouTubeMediaKind: String, Codable, CaseIterable, Sendable {
    case video
    case audio

    public var title: String { self == .video ? "Video (MP4)" : "Audio (MP3)" }
    public var fileExtension: String { self == .video ? "mp4" : "mp3" }
}

// MARK: - Login

/// Where yt-dlp takes the YouTube login from (`--cookies-from-browser`). No password is ever
/// asked for: the browser's existing YouTube session is used.
public enum YouTubeLoginBrowser: String, Codable, CaseIterable, Sendable {
    case none, safari, chrome, firefox, brave, edge, vivaldi, opera, chromium

    public var title: String {
        switch self {
        case .none: return "Not logged in"
        case .safari: return "Safari"
        case .chrome: return "Chrome"
        case .firefox: return "Firefox"
        case .brave: return "Brave"
        case .edge: return "Edge"
        case .vivaldi: return "Vivaldi"
        case .opera: return "Opera"
        case .chromium: return "Chromium"
        }
    }

    /// Value for `--cookies-from-browser`.
    public var ytDlpName: String? { self == .none ? nil : rawValue }

    public var bundleIdentifier: String? {
        switch self {
        case .none: return nil
        case .safari: return "com.apple.Safari"
        case .chrome: return "com.google.Chrome"
        case .firefox: return "org.mozilla.firefox"
        case .brave: return "com.brave.Browser"
        case .edge: return "com.microsoft.edgemac"
        case .vivaldi: return "com.vivaldi.Vivaldi"
        case .opera: return "com.operasoftware.Opera"
        case .chromium: return "org.chromium.Chromium"
        }
    }
}

// MARK: - Links

public struct YouTubeLink: Equatable, Sendable {
    public let url: String
    /// The link names a playlist (or channel) rather than a single video.
    public let isPlaylist: Bool
}

public enum YouTubeLinkParser {
    /// Pulls every http(s) link out of pasted text (one or more per line, any separators).
    /// Duplicates are dropped, order is kept.
    public static func links(in text: String) -> [YouTubeLink] {
        var seen = Set<String>()
        var result: [YouTubeLink] = []
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'<>,;"))
        for token in text.components(separatedBy: separators) where !token.isEmpty {
            var candidate = token
            if !candidate.lowercased().hasPrefix("http") {
                // Bare "youtu.be/…" or "www.youtube.com/…" pasted without the scheme.
                let lower = candidate.lowercased()
                guard lower.hasPrefix("youtu.be/") || lower.hasPrefix("www.youtube.com/")
                        || lower.hasPrefix("youtube.com/") || lower.hasPrefix("m.youtube.com/")
                        || lower.hasPrefix("music.youtube.com/") else { continue }
                candidate = "https://" + candidate
            }
            guard let comps = URLComponents(string: candidate),
                  let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = comps.host, !host.isEmpty else { continue }
            guard seen.insert(candidate).inserted else { continue }
            result.append(YouTubeLink(url: candidate, isPlaylist: isPlaylist(comps)))
        }
        return result
    }

    static func isYouTubeHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "youtu.be" || h == "youtube.com" || h.hasSuffix(".youtube.com")
    }

    /// A watch link that also carries `list=` (a video opened from a playlist) downloads only
    /// that video; `/playlist?list=…`, channel and other non-watch links download everything.
    static func isPlaylist(_ comps: URLComponents) -> Bool {
        guard let host = comps.host, isYouTubeHost(host) else { return false }
        let path = comps.path.lowercased()
        let items = comps.queryItems ?? []
        let hasList = items.contains { $0.name == "list" && !($0.value ?? "").isEmpty }
        if host.lowercased() == "youtu.be" { return false }
        if path.hasPrefix("/watch") || path.hasPrefix("/shorts/") || path.hasPrefix("/live/") { return false }
        if path.hasPrefix("/playlist") { return hasList }
        if path.hasPrefix("/@") || path.hasPrefix("/channel/") || path.hasPrefix("/c/") || path.hasPrefix("/user/") {
            return true
        }
        return hasList
    }
}

// MARK: - Toolchain

public struct YouTubeToolchain: Equatable, Sendable {
    public enum JSRuntime: Equatable, Sendable {
        case deno(String)
        case node(String)

        public var path: String {
            switch self {
            case .deno(let p), .node(let p): return p
            }
        }

        var argument: String {
            switch self {
            case .deno(let p): return "deno:" + p
            case .node(let p): return "node:" + p
            }
        }
    }

    public var ytDlp: String?
    public var ffmpeg: String?
    public var ffprobe: String?
    public var jsRuntime: JSRuntime?

    public init(ytDlp: String? = nil, ffmpeg: String? = nil, ffprobe: String? = nil, jsRuntime: JSRuntime? = nil) {
        self.ytDlp = ytDlp
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
        self.jsRuntime = jsRuntime
    }

    public var isComplete: Bool { ytDlp != nil && ffmpeg != nil && ffprobe != nil && jsRuntime != nil }

    public var missing: [String] {
        var m: [String] = []
        if ytDlp == nil { m.append("yt-dlp") }
        if ffmpeg == nil || ffprobe == nil { m.append("ffmpeg") }
        if jsRuntime == nil { m.append("deno") }
        return m
    }

    /// ~/Library/Application Support/CZ.commander/tools
    public static var toolsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("CZ.commander/tools", isDirectory: true)
    }

    /// ~/Downloads/YoutubeZ
    public static var downloadsDirectory: URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        return downloads.appendingPathComponent("YoutubeZ", isDirectory: true)
    }

    static let systemBinDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// Finds usable tools: our own copies first, then Homebrew / /usr/local.
    /// Too old or non-working ffmpeg / node builds are ignored (an ffmpeg 2.x cannot merge
    /// modern YouTube streams).
    public static func locate(toolsDirectory: URL = toolsDirectory) -> YouTubeToolchain {
        let own = toolsDirectory.path
        var chain = YouTubeToolchain()

        chain.ytDlp = firstExecutable(named: "yt-dlp", in: [own] + systemBinDirectories)

        for dir in [own] + systemBinDirectories {
            let ff = (dir as NSString).appendingPathComponent("ffmpeg")
            let fp = (dir as NSString).appendingPathComponent("ffprobe")
            guard isExecutable(ff), isExecutable(fp) else { continue }
            if dir == own || ffmpegIsRecent(ff) {
                chain.ffmpeg = ff
                chain.ffprobe = fp
                break
            }
        }

        let home = NSHomeDirectory()
        if let deno = firstExecutable(named: "deno", in: [own] + systemBinDirectories + [home + "/.deno/bin"]) {
            chain.jsRuntime = .deno(deno)
        } else {
            for dir in systemBinDirectories {
                let node = (dir as NSString).appendingPathComponent("node")
                if isExecutable(node), let major = nodeMajorVersion(node), major >= 20 {
                    chain.jsRuntime = .node(node)
                    break
                }
            }
        }
        return chain
    }

    static func isExecutable(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    static func firstExecutable(named name: String, in dirs: [String]) -> String? {
        for dir in dirs {
            let p = (dir as NSString).appendingPathComponent(name)
            if isExecutable(p) { return p }
        }
        return nil
    }

    static func ffmpegIsRecent(_ path: String) -> Bool {
        guard let out = YouTubeProcess.capture(path, ["-hide_banner", "-version"], timeout: 8) else { return false }
        return parseFFmpegMajorVersion(out).map { $0 >= 5 } ?? false
    }

    /// "ffmpeg version 7.1.1 …" → 7, "ffmpeg version N-129157-g…" (git snapshot) → 99.
    public static func parseFFmpegMajorVersion(_ output: String) -> Int? {
        guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix("ffmpeg version ") }) else { return nil }
        let rest = line.dropFirst("ffmpeg version ".count)
        if rest.hasPrefix("N-") || rest.hasPrefix("git-") { return 99 }
        let digits = rest.prefix(while: { $0.isNumber })
        return Int(digits)
    }

    static func nodeMajorVersion(_ path: String) -> Int? {
        guard let out = YouTubeProcess.capture(path, ["--version"], timeout: 8) else { return nil }
        return parseNodeMajorVersion(out)
    }

    /// "v24.16.0" → 24
    public static func parseNodeMajorVersion(_ output: String) -> Int? {
        let t = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("v") else { return nil }
        return Int(t.dropFirst().prefix(while: { $0.isNumber }))
    }
}

// MARK: - Installer

public struct YouTubeToolInstallError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

public enum YouTubeToolInstaller {
    public struct Source: Sendable {
        public let name: String
        public let url: URL
        /// Where the expected hash comes from.
        public let checksum: Checksum
        /// Files to take from the download (a zip is unpacked first).
        public let files: [String]
        public let isZip: Bool
    }

    public enum Checksum: Sendable {
        /// A `SHA2-256SUMS`-style list next to the download; the line for `fileName` is used.
        case list(URL, fileName: String)
        /// `<final download URL>.sha256` (the server redirects to a versioned file).
        case sibling
    }

    public static let ytDlpSource = Source(
        name: "yt-dlp",
        url: URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!,
        checksum: .list(URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS")!, fileName: "yt-dlp_macos"),
        files: ["yt-dlp"],
        isZip: false)

    public static var ffmpegSources: [Source] {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "amd64"
        #endif
        return ["ffmpeg", "ffprobe"].map { tool in
            Source(
                name: tool,
                url: URL(string: "https://ffmpeg.martin-riedl.de/redirect/latest/macos/\(arch)/release/\(tool).zip")!,
                checksum: .sibling,
                files: [tool],
                isZip: true)
        }
    }

    public static var denoSource: Source {
        #if arch(arm64)
        let file = "deno-aarch64-apple-darwin.zip"
        #else
        let file = "deno-x86_64-apple-darwin.zip"
        #endif
        return Source(
            name: "deno",
            url: URL(string: "https://github.com/denoland/deno/releases/latest/download/\(file)")!,
            checksum: .list(URL(string: "https://github.com/denoland/deno/releases/latest/download/\(file).sha256sum")!, fileName: file),
            files: ["deno"],
            isZip: true)
    }

    /// Sources needed to complete `chain`.
    public static func sources(for chain: YouTubeToolchain) -> [Source] {
        var list: [Source] = []
        if chain.ytDlp == nil { list.append(ytDlpSource) }
        if chain.ffmpeg == nil || chain.ffprobe == nil { list += ffmpegSources }
        if chain.jsRuntime == nil { list.append(denoSource) }
        return list
    }

    /// Finds the hash for `fileName` in a `<hash>  <name>` list. A single-line file without a
    /// name is accepted too.
    public static func expectedHash(in list: String, fileName: String) -> String? {
        let lines = list.split(whereSeparator: \.isNewline).map { String($0) }
        for line in lines {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let hash = parts.first, isHexHash(hash) else { continue }
            if parts.count == 1 && lines.count == 1 { return hash.lowercased() }
            if let name = parts.last, name.trimmingCharacters(in: CharacterSet(charactersIn: "*")) == fileName {
                return hash.lowercased()
            }
        }
        return nil
    }

    static func isHexHash(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { $0.isHexDigit }
    }

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Downloads, verifies and installs `sources` into `toolsDirectory`.
    public static func install(
        _ sources: [Source],
        toolsDirectory: URL = YouTubeToolchain.toolsDirectory,
        status: @escaping @Sendable (String) -> Void
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: toolsDirectory, withIntermediateDirectories: true)
        let session = URLSession(configuration: .ephemeral)

        for source in sources {
            status("Downloading \(source.name)…")
            let (tmpFile, response) = try await session.download(from: source.url)
            defer { try? fm.removeItem(at: tmpFile) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw YouTubeToolInstallError(message: "\(source.name): download failed (\((response as? HTTPURLResponse)?.statusCode ?? 0)).")
            }

            status("Verifying \(source.name)…")
            let expected: String?
            switch source.checksum {
            case .list(let listURL, let fileName):
                let (data, _) = try await session.data(from: listURL)
                expected = expectedHash(in: String(decoding: data, as: UTF8.self), fileName: fileName)
            case .sibling:
                let finalURL = http.url ?? source.url
                let (data, resp) = try await session.data(from: URL(string: finalURL.absoluteString + ".sha256")!)
                let fileName = finalURL.lastPathComponent
                expected = (resp as? HTTPURLResponse)?.statusCode == 200
                    ? expectedHash(in: String(decoding: data, as: UTF8.self), fileName: fileName) : nil
            }
            guard let expected else {
                throw YouTubeToolInstallError(message: "\(source.name): no checksum published, not installed.")
            }
            let actual = try sha256(of: tmpFile)
            guard actual == expected else {
                throw YouTubeToolInstallError(message: "\(source.name): checksum mismatch, not installed.")
            }

            status("Installing \(source.name)…")
            let staging = fm.temporaryDirectory.appendingPathComponent("czc-tool-" + UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: staging) }

            if source.isZip {
                let zip = staging.appendingPathComponent("download.zip")
                try fm.moveItem(at: tmpFile, to: zip)
                let unpacked = staging.appendingPathComponent("out", isDirectory: true)
                guard YouTubeProcess.capture("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path], timeout: 120) != nil else {
                    throw YouTubeToolInstallError(message: "\(source.name): could not unpack.")
                }
                for name in source.files {
                    guard let found = findFile(named: name, under: unpacked) else {
                        throw YouTubeToolInstallError(message: "\(source.name): \(name) missing from the download.")
                    }
                    try place(found, as: name, in: toolsDirectory)
                }
            } else {
                let file = staging.appendingPathComponent(source.files[0])
                try fm.moveItem(at: tmpFile, to: file)
                try place(file, as: source.files[0], in: toolsDirectory)
            }
        }
        status("Tools ready.")
    }

    static func findFile(named name: String, under dir: URL) -> URL? {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return nil }
        for case let url as URL in e where url.lastPathComponent == name {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { return url }
        }
        return nil
    }

    static func place(_ file: URL, as name: String, in dir: URL) throws {
        let fm = FileManager.default
        let target = dir.appendingPathComponent(name)
        try? fm.removeItem(at: target)
        try fm.moveItem(at: file, to: target)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        // Never quarantined by URLSession, but strip it in case the folder was copied around.
        _ = YouTubeProcess.capture("/usr/bin/xattr", ["-d", "com.apple.quarantine", target.path], timeout: 10)
    }

    /// Our own yt-dlp copy updates itself (YouTube changes often); at most once a day.
    public static func shouldSelfUpdate(ytDlp: String, toolsDirectory: URL = YouTubeToolchain.toolsDirectory, now: Date = Date()) -> Bool {
        guard ytDlp.hasPrefix(toolsDirectory.path + "/") else { return false }
        let marker = toolsDirectory.appendingPathComponent(".yt-dlp-update-check")
        let last = (try? FileManager.default.attributesOfItem(atPath: marker.path)[.modificationDate] as? Date) ?? .distantPast
        return now.timeIntervalSince(last) > 24 * 3600
    }

    public static func markSelfUpdateChecked(toolsDirectory: URL = YouTubeToolchain.toolsDirectory) {
        let marker = toolsDirectory.appendingPathComponent(".yt-dlp-update-check")
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: marker.path)
    }
}

// MARK: - yt-dlp command line

public enum YouTubeCommand {
    public static let progressPrefix = "CZP|"
    public static let itemPrefix = "CZI|"
    public static let filePrefix = "CZF|"

    /// Arguments for one link. Output goes to `outputDirectory`; a playlist gets its own
    /// sub-folder with numbered files.
    public static func arguments(for link: YouTubeLink, kind: YouTubeMediaKind, outputDirectory: String, toolchain: YouTubeToolchain, login: YouTubeLoginBrowser = .none) -> [String] {
        var args: [String] = [
            "--newline",
            "--color", "never",
            "--ignore-errors",
            "--no-mtime",
            "--no-overwrites",
            "--continue",
            "--concurrent-fragments", "4",
            "--progress",
            "--no-simulate",
            "--progress-template",
            "download:" + progressPrefix + "%(progress.downloaded_bytes)s|%(progress.total_bytes,progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s",
            "--print", "before_dl:" + itemPrefix + "%(playlist_index)s|%(n_entries)s|%(title)s",
            "--print", "after_move:" + filePrefix + "%(filepath)s",
            "-P", outputDirectory,
            "-o", link.isPlaylist
                ? "%(playlist_title,playlist_id)s/%(playlist_index)03d - %(title)s.%(ext)s"
                : "%(title)s.%(ext)s",
            "--trim-filenames", "180",
            "--embed-metadata",
            "--embed-thumbnail",
            "--convert-thumbnails", "jpg",
            link.isPlaylist ? "--yes-playlist" : "--no-playlist",
        ]
        if let ffmpeg = toolchain.ffmpeg {
            args += ["--ffmpeg-location", (ffmpeg as NSString).deletingLastPathComponent]
        }
        if let js = toolchain.jsRuntime {
            args += ["--js-runtimes", js.argument]
        }
        if let browser = login.ytDlpName {
            args += ["--cookies-from-browser", browser]
            // Go easy on a logged-in account: Google may flag bulk downloads.
            args += ["--sleep-requests", "0.75"]
            if link.isPlaylist {
                args += ["--sleep-interval", "3", "--max-sleep-interval", "8"]
            }
        }
        switch kind {
        case .video:
            // Highest resolution and frame rate first; at equal resolution H.264 + AAC wins
            // (plays everywhere, QuickTime included). 4K and up only exist as VP9 / AV1.
            // Logged in, the higher bitrate wins first, so YouTube Premium's
            // "1080p Premium" (enhanced bitrate) stream is picked when the account has it.
            args += [
                "-f", "bv*+ba/b",
                "-S", login == .none ? "res,fps,vcodec:h264,acodec:aac" : "res,fps,vbr,vcodec:h264,acodec:aac",
                "--merge-output-format", "mp4",
                "--embed-chapters",
            ]
        case .audio:
            args += [
                "-f", "ba/b",
                // Highest audio bitrate as the MP3 source (256 kbps AAC with Premium).
                "-S", "abr,asr",
                "--extract-audio",
                "--audio-format", "mp3",
                "--audio-quality", "0",
            ]
        }
        args += ["--", link.url]
        return args
    }
}

// MARK: - Output parsing

public enum YouTubeOutputEvent: Equatable, Sendable {
    case progress(downloaded: Int64?, total: Int64?, speed: Double?, eta: Int?)
    case item(index: Int?, count: Int?, title: String)
    case file(String)
    case error(String)
    case warning(String)
    case other(String)
}

public enum YouTubeOutputParser {
    /// YouTube refused without a login ("Sign in to confirm you're not a bot", age limit,
    /// members-only, private playlist).
    public static func needsLogin(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("sign in to confirm") || m.contains("--cookies-from-browser")
            || m.contains("login required") || m.contains("members-only")
            || m.contains("private video") || m.contains("this playlist is private")
    }

    public static func parse(_ rawLine: String) -> YouTubeOutputEvent {
        let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        if line.hasPrefix(YouTubeCommand.progressPrefix) {
            let f = line.dropFirst(YouTubeCommand.progressPrefix.count).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            func num(_ i: Int) -> Double? {
                guard i < f.count else { return nil }
                return Double(f[i].trimmingCharacters(in: .whitespaces))
            }
            return .progress(
                downloaded: num(0).map { Int64($0) },
                total: num(1).map { Int64($0) },
                speed: num(2),
                eta: num(3).map { Int($0) })
        }
        if line.hasPrefix(YouTubeCommand.itemPrefix) {
            let f = line.dropFirst(YouTubeCommand.itemPrefix.count).split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            let title = f.count > 2 ? f[2] : ""
            return .item(index: f.count > 0 ? Int(f[0]) : nil, count: f.count > 1 ? Int(f[1]) : nil, title: title)
        }
        if line.hasPrefix(YouTubeCommand.filePrefix) {
            return .file(String(line.dropFirst(YouTubeCommand.filePrefix.count)))
        }
        if line.hasPrefix("ERROR:") {
            return .error(line.dropFirst("ERROR:".count).trimmingCharacters(in: .whitespaces))
        }
        if line.hasPrefix("WARNING:") {
            return .warning(line.dropFirst("WARNING:".count).trimmingCharacters(in: .whitespaces))
        }
        return .other(line)
    }
}

// MARK: - Small process helper

public enum YouTubeProcess {
    /// Runs a short command and returns its combined output, or nil if it failed / timed out.
    public static func capture(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let done = DispatchSemaphore(value: 0)
        var data = Data()
        DispatchQueue.global(qos: .utility).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return nil
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Environment for yt-dlp: UTF-8 output and our tools first on PATH.
    public static func environment(toolchain: YouTubeToolchain) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        var dirs: [String] = [YouTubeToolchain.toolsDirectory.path]
        for tool in [toolchain.ffmpeg, toolchain.jsRuntime?.path] {
            if let t = tool { dirs.append((t as NSString).deletingLastPathComponent) }
        }
        dirs += YouTubeToolchain.systemBinDirectories + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var unique: [String] = []
        for d in dirs where !unique.contains(d) { unique.append(d) }
        env["PATH"] = unique.joined(separator: ":")
        env["PYTHONIOENCODING"] = "utf-8"
        env["PYTHONUNBUFFERED"] = "1"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        return env
    }
}
