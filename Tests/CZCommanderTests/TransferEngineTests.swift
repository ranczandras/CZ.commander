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
