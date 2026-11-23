import XCTest
@testable import CZCommanderCore

final class YouTubeDownloadEngineTests: XCTestCase {

    func testLinkParsingFindsVideosPlaylistsAndDropsDuplicates() {
        let text = """
        https://www.youtube.com/watch?v=abc123
        nézd: https://youtu.be/xyz789?si=1, https://www.youtube.com/playlist?list=PL42
        https://www.youtube.com/watch?v=abc123
        youtube.com/@SomeChannel
        not a link
        https://www.youtube.com/watch?v=vid&list=PL99
        """
        let links = YouTubeLinkParser.links(in: text)
        XCTAssertEqual(links.map(\.url), [
            "https://www.youtube.com/watch?v=abc123",
            "https://youtu.be/xyz789?si=1",
            "https://www.youtube.com/playlist?list=PL42",
            "https://youtube.com/@SomeChannel",
            "https://www.youtube.com/watch?v=vid&list=PL99",
        ])
        XCTAssertEqual(links.map(\.isPlaylist), [false, false, true, true, false])
    }

    func testVideoArgumentsMergeBestStreamsIntoMP4() {
        let chain = YouTubeToolchain(ytDlp: "/t/yt-dlp", ffmpeg: "/t/ffmpeg", ffprobe: "/t/ffprobe", jsRuntime: .node("/usr/local/bin/node"))
        let link = YouTubeLink(url: "https://youtu.be/x", isPlaylist: false)
        let args = YouTubeCommand.arguments(for: link, kind: .video, outputDirectory: "/out", toolchain: chain)
        XCTAssertEqual(value(after: "-f", in: args), "bv*+ba/b")
        XCTAssertEqual(value(after: "--merge-output-format", in: args), "mp4")
        XCTAssertEqual(value(after: "-P", in: args), "/out")
        XCTAssertEqual(value(after: "-o", in: args), "%(title)s.%(ext)s")
        XCTAssertEqual(value(after: "--ffmpeg-location", in: args), "/t")
        XCTAssertEqual(value(after: "--js-runtimes", in: args), "node:/usr/local/bin/node")
        XCTAssertTrue(args.contains("--no-playlist"))
        XCTAssertFalse(args.contains("--extract-audio"))
        XCTAssertEqual(Array(args.suffix(2)), ["--", "https://youtu.be/x"])
    }

    func testAudioPlaylistArgumentsExtractMP3IntoPlaylistFolder() {
        let chain = YouTubeToolchain(ytDlp: "/t/yt-dlp", ffmpeg: "/t/ffmpeg", ffprobe: "/t/ffprobe", jsRuntime: .deno("/t/deno"))
        let link = YouTubeLink(url: "https://www.youtube.com/playlist?list=PL1", isPlaylist: true)
        let args = YouTubeCommand.arguments(for: link, kind: .audio, outputDirectory: "/out", toolchain: chain)
        XCTAssertEqual(value(after: "-f", in: args), "ba/b")
        XCTAssertEqual(value(after: "--audio-format", in: args), "mp3")
        XCTAssertEqual(value(after: "--audio-quality", in: args), "0")
        XCTAssertTrue(args.contains("--extract-audio"))
        XCTAssertTrue(args.contains("--yes-playlist"))
        XCTAssertTrue(value(after: "-o", in: args)?.hasPrefix("%(playlist_title,playlist_id)s/%(playlist_index)03d - ") == true)
        XCTAssertEqual(value(after: "--js-runtimes", in: args), "deno:/t/deno")
    }

    func testOutputParsing() {
        XCTAssertEqual(YouTubeOutputParser.parse("CZP|1048576|4194304|524288.5|6\n"),
                       .progress(downloaded: 1_048_576, total: 4_194_304, speed: 524_288.5, eta: 6))
        XCTAssertEqual(YouTubeOutputParser.parse("CZP|100|NA|NA|NA"),
                       .progress(downloaded: 100, total: nil, speed: nil, eta: nil))
        XCTAssertEqual(YouTubeOutputParser.parse("CZI|3|12|A | B title"),
                       .item(index: 3, count: 12, title: "A | B title"))
        XCTAssertEqual(YouTubeOutputParser.parse("CZI|NA|NA|Single"),
                       .item(index: nil, count: nil, title: "Single"))
        XCTAssertEqual(YouTubeOutputParser.parse("CZF|/out/Song.mp3"), .file("/out/Song.mp3"))
        XCTAssertEqual(YouTubeOutputParser.parse("ERROR: [youtube] x: Video unavailable"), .error("[youtube] x: Video unavailable"))
        XCTAssertEqual(YouTubeOutputParser.parse("WARNING: slow"), .warning("slow"))
    }

    func testChecksumListAndVersionParsing() {
        let list = """
        0f922c15ccc0b83eefa1c8bc9104e434318c4bf16e408e1ee93b7745a6efe0aa  yt-dlp_macos
        20d98fa608998eff87d1d35a6e9fb65e4b874639a6cc89addc19da3becde3ef1  yt-dlp_macos.zip
        """
        XCTAssertEqual(YouTubeToolInstaller.expectedHash(in: list, fileName: "yt-dlp_macos"),
                       "0f922c15ccc0b83eefa1c8bc9104e434318c4bf16e408e1ee93b7745a6efe0aa")
        XCTAssertNil(YouTubeToolInstaller.expectedHash(in: list, fileName: "yt-dlp"))

        XCTAssertEqual(YouTubeToolchain.parseFFmpegMajorVersion("ffmpeg version 2.8.1-tessus Copyright"), 2)
        XCTAssertEqual(YouTubeToolchain.parseFFmpegMajorVersion("ffmpeg version 9.1 Copyright"), 9)
        XCTAssertEqual(YouTubeToolchain.parseFFmpegMajorVersion("ffmpeg version N-129157-g9ced9e345c"), 99)
        XCTAssertEqual(YouTubeToolchain.parseNodeMajorVersion("v24.16.0\n"), 24)
    }

    func testSHA256OfFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("czc-sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try YouTubeToolInstaller.sha256(of: url),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testLocateIgnoresTooOldFFmpegButUsesOwnTools() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("czc-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["yt-dlp", "ffmpeg", "ffprobe", "deno"] {
            let p = dir.appendingPathComponent(name).path
            FileManager.default.createFile(atPath: p, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        }
        let chain = YouTubeToolchain.locate(toolsDirectory: dir)
        XCTAssertEqual(chain.ytDlp, dir.appendingPathComponent("yt-dlp").path)
        XCTAssertEqual(chain.ffmpeg, dir.appendingPathComponent("ffmpeg").path)
        XCTAssertEqual(chain.jsRuntime, .deno(dir.appendingPathComponent("deno").path))
        XCTAssertTrue(chain.isComplete)
    }

    private func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}
