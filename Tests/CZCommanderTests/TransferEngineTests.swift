import XCTest
@testable import CZCommanderCore

final class TransferEngineTests: XCTestCase {
    private var root: String!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("czc-xfer-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(atPath: root)
    }

    private func write(_ rel: String, _ text: String) {
        let p = root + "/" + rel
        try? fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        fm.createFile(atPath: p, contents: Data(text.utf8))
    }

    private func read(_ rel: String) -> String? {
        (try? String(contentsOfFile: root + "/" + rel, encoding: .utf8))
    }

    func testCopyTreeReportsProgressToTheEnd() throws {
        write("src/A/one.txt", String(repeating: "1", count: 1000))
        write("src/A/sub/two.txt", String(repeating: "2", count: 3000))
        write("src/three.txt", "333")
        var last = FileOperationProgress()
        let lock = NSLock()
        try TransferEngine.copyOrMove(sources: [root + "/src/A", root + "/src/three.txt"], to: root + "/dst", isMove: false) { p in
            lock.lock(); last = p; lock.unlock()
        }
        XCTAssertEqual(read("dst/A/sub/two.txt")?.count, 3000)
        XCTAssertEqual(read("dst/three.txt"), "333")
        XCTAssertEqual(last.totalFiles, 3)
        XCTAssertEqual(last.totalBytes, 4003)
        XCTAssertEqual(last.processedBytes, 4003)
        XCTAssertEqual(last.processedFiles, 3)
        XCTAssertFalse(last.isScanning)
        XCTAssertTrue(fm.fileExists(atPath: root + "/src/A/one.txt"), "copy keeps the source")
    }

    func testFolderMergesInsteadOfReplacingExistingFolder() throws {
        write("src/Photos/new.jpg", "new")
        write("src/Photos/same.jpg", "fresh")
        write("dst/Photos/keep.jpg", "old-only-in-target")
        write("dst/Photos/same.jpg", "stale")
        try TransferEngine.copyOrMove(sources: [root + "/src/Photos"], to: root + "/dst", isMove: false,
                                      options: FileOperationOptions(overwritePolicy: .overwriteAll))
        XCTAssertEqual(read("dst/Photos/keep.jpg"), "old-only-in-target", "existing files in the target folder survive")
        XCTAssertEqual(read("dst/Photos/new.jpg"), "new")
        XCTAssertEqual(read("dst/Photos/same.jpg"), "fresh")
    }

    func testSkipPolicyKeepsTargetAndStillCompletes() throws {
        write("src/a.txt", "source")
        write("dst/a.txt", "target")
        var last = FileOperationProgress()
        try TransferEngine.copyOrMove(sources: [root + "/src/a.txt"], to: root + "/dst", isMove: false,
                                      options: FileOperationOptions(overwritePolicy: .skipAll)) { last = $0 }
        XCTAssertEqual(read("dst/a.txt"), "target")
        XCTAssertEqual(last.fractionCompleted, 1, accuracy: 0.0001)
    }

    func testMoveRenamesOnSameVolumeAndMovesFolders() throws {
        write("src/Docs/x.txt", "x")
        write("src/y.txt", "y")
        let created = try TransferEngine.copyOrMove(sources: [root + "/src/Docs", root + "/src/y.txt"], to: root + "/dst", isMove: true)
        XCTAssertEqual(Set(created), [root + "/dst/Docs", root + "/dst/y.txt"])
        XCTAssertEqual(read("dst/Docs/x.txt"), "x")
        XCTAssertFalse(fm.fileExists(atPath: root + "/src/Docs"))
        XCTAssertFalse(fm.fileExists(atPath: root + "/src/y.txt"))
    }

    func testCopyIntoSameFolderMakesACopy() throws {
        write("dir/file.txt", "a")
        let created = try TransferEngine.copyOrMove(sources: [root + "/dir/file.txt"], to: root + "/dir", isMove: false)
        XCTAssertEqual(created.count, 1)
        XCTAssertNotEqual(created[0], root + "/dir/file.txt")
        XCTAssertEqual(read("dir/file.txt"), "a")
    }

    func testCancelStopsAndLeavesNoPartialFile() throws {
        write("src/a.txt", "a")
        write("src/b.txt", "b")
        let control = TransferControl()
        control.cancel()
        XCTAssertThrowsError(try TransferEngine.copyOrMove(sources: [root + "/src/a.txt", root + "/src/b.txt"], to: root + "/dst",
                                                           isMove: false, control: control)) { error in
            XCTAssertTrue(error is TransferCancelledError)
        }
        XCTAssertFalse(fm.fileExists(atPath: root + "/dst/b.txt"))
    }

    func testPauseBlocksUntilResumed() throws {
        write("src/a.txt", "a")
        let control = TransferControl()
        control.pause()
        let done = expectation(description: "copy finished")
        DispatchQueue.global().async {
            _ = try? TransferEngine.copyOrMove(sources: [self.root + "/src/a.txt"], to: self.root + "/dst", isMove: false, control: control)
            done.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(fm.fileExists(atPath: root + "/dst/a.txt"), "nothing copied while paused")
        control.resume()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(read("dst/a.txt"), "a")
    }

    func testUnpackWithProgressReachesTotal() throws {
        write("pack/Folder/in.txt", String(repeating: "z", count: 5000))
        write("pack/loose.txt", "loose")
        let zip = root + "/a.zip"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = URL(fileURLWithPath: root + "/pack")
        p.arguments = ["-qr", zip, "Folder", "loose.txt"]
        try p.run(); p.waitUntilExit()

        var last = FileOperationProgress()
        let lock = NSLock()
        let out = try ArchiveEngine.unpackArchive(archivePath: zip, toDirectory: root + "/out", control: TransferControl()) { pr in
            lock.lock(); last = pr; lock.unlock()
        }
        XCTAssertEqual(out, root + "/out/a")
        XCTAssertEqual(read("out/a/Folder/in.txt")?.count, 5000)
        XCTAssertEqual(last.totalFiles, 2)
        XCTAssertEqual(last.processedBytes, last.totalBytes)
        XCTAssertGreaterThan(last.totalBytes, 5000)
    }

    func testSpeedAndRemainingTime() {
        var p = FileOperationProgress(processedBytes: 100, totalBytes: 1100, bytesPerSecond: 100)
        XCTAssertEqual(p.remainingSeconds ?? -1, 10, accuracy: 0.001)
        p.bytesPerSecond = 0
        XCTAssertNil(p.remainingSeconds)
    }
}

final class TransferConflictTests: XCTestCase {
    private var root: String!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("czc-conf-\(UUID().uuidString)").path
        for d in ["src", "dst"] { try fm.createDirectory(atPath: root + "/" + d, withIntermediateDirectories: true) }
        for n in ["a", "b", "c"] {
            fm.createFile(atPath: root + "/src/\(n).txt", contents: Data("new-\(n)".utf8))
            fm.createFile(atPath: root + "/dst/\(n).txt", contents: Data("old-\(n)".utf8))
        }
        fm.createFile(atPath: root + "/src/d.txt", contents: Data("only-new".utf8))
    }

    override func tearDownWithError() throws { try? fm.removeItem(atPath: root) }

    private func text(_ rel: String) -> String? { try? String(contentsOfFile: root + "/" + rel, encoding: .utf8) }

    private func run(_ answers: [TransferConflictDecision]) throws -> (asked: Int, progress: FileOperationProgress) {
        let control = TransferControl()
        let lock = NSLock()
        var queue = answers
        var asked = 0
        control.conflictResolver = { _ in
            lock.withLock { asked += 1; return queue.isEmpty ? .skip : queue.removeFirst() }
        }
        var last = FileOperationProgress()
        let srcs = ["a", "b", "c", "d"].map { root + "/src/\($0).txt" }
        try TransferEngine.copyOrMove(sources: srcs, to: root + "/dst", isMove: false,
                                      options: FileOperationOptions(overwritePolicy: .ask), control: control) { last = $0 }
        return (asked, last)
    }

    func testSkipAllAsksOnceAndCopiesOnlyMissing() throws {
        let r = try run([.skipAll])
        XCTAssertEqual(r.asked, 1)
        XCTAssertEqual(text("dst/a.txt"), "old-a")
        XCTAssertEqual(text("dst/c.txt"), "old-c")
        XCTAssertEqual(text("dst/d.txt"), "only-new")
        XCTAssertEqual(r.progress.skippedFiles, 3)
    }

    func testOverwriteThenSkipThenRename() throws {
        let r = try run([.overwrite, .skip, .rename])
        XCTAssertEqual(r.asked, 3)
        XCTAssertEqual(text("dst/a.txt"), "new-a")
        XCTAssertEqual(text("dst/b.txt"), "old-b")
        XCTAssertEqual(text("dst/c.txt"), "old-c")
        let names = try fm.contentsOfDirectory(atPath: root + "/dst")
        XCTAssertEqual(names.filter { $0.hasPrefix("c") }.count, 2, "renamed copy next to the original")
        XCTAssertEqual(r.progress.skippedFiles, 1)
    }

    func testCancelStops() {
        XCTAssertThrowsError(try run([.cancel])) { XCTAssertTrue($0 is TransferCancelledError) }
        XCTAssertEqual(text("dst/a.txt"), "old-a")
        XCTAssertNil(text("dst/d.txt"))
    }
}

final class MoveAtEndTests: XCTestCase {
    func testCrossVolumeStyleMoveDeletesOnlyAfterEverythingCopied() throws {
        // Same volume would be a rename; copyTree with isMove exercises the copy+delete path.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("czc-mv-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: root) }
        try fm.createDirectory(atPath: root + "/src/A/sub", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/dst", withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/src/A/one.txt", contents: Data("1".utf8))
        fm.createFile(atPath: root + "/src/A/sub/two.txt", contents: Data("2".utf8))

        let reporter = TransferReporter(handler: nil)
        let ledger = TransferEngine.MoveLedger()
        _ = try TransferEngine.copyTree(src: root + "/src/A", dst: root + "/dst/A", isMove: true,
                                        options: FileOperationOptions(), control: nil, reporter: reporter, ledger: ledger)
        // Nothing removed yet: the sources wait for the end of the whole job.
        XCTAssertTrue(fm.fileExists(atPath: root + "/src/A/sub/two.txt"))
        XCTAssertTrue(fm.fileExists(atPath: root + "/dst/A/sub/two.txt"))
        XCTAssertEqual(ledger.files.count, 2)
        XCTAssertEqual(ledger.directories.last, root + "/src/A", "folders in post-order, the top one last")
    }

    func testCancelledMoveKeepsSources() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("czc-mv2-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: root) }
        try fm.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/src/a.txt", contents: Data("a".utf8))
        fm.createFile(atPath: root + "/src/b.txt", contents: Data("b".utf8))
        let control = TransferControl()
        var answered = 0
        control.conflictResolver = { _ in answered += 1; return .cancel }
        try fm.createDirectory(atPath: root + "/dst", withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/dst/b.txt", contents: Data("old".utf8))
        XCTAssertThrowsError(try TransferEngine.copyOrMove(sources: [root + "/src/a.txt", root + "/src/b.txt"],
                                                           to: root + "/dst", isMove: true,
                                                           options: FileOperationOptions(overwritePolicy: .ask), control: control))
        XCTAssertTrue(fm.fileExists(atPath: root + "/src/b.txt"))
    }
}
