import XCTest
@testable import CZCommanderCore

final class CZCommanderCoreTests: XCTestCase {
    private var tempRoot: String!

    override func setUpWithError() throws {
        tempRoot = (NSTemporaryDirectory() as NSString).appendingPathComponent("tc_tests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root = tempRoot, FileManager.default.fileExists(atPath: root) {
            try? FileManager.default.removeItem(atPath: root)
        }
    }

    // MARK: - 1. FileSystemEngine Tests (Listing, MkDir, Copy/Move, Masks, Comments, Attributes, Branch View)

    func testCreateDirectoriesAndList() throws {
        let created = try FileSystemEngine.createDirectories(
            expression: "alpha|beta|nested/gamma",
            in: tempRoot
        )
        XCTAssertEqual(created.count, 3)

        let listed = try FileSystemEngine.listDirectory(at: tempRoot, showHidden: true, includeParentEntry: true)
        let names = Set(listed.map { $0.name })
        XCTAssertTrue(names.contains(".."))
        XCTAssertTrue(names.contains("alpha"))
        XCTAssertTrue(names.contains("beta"))
        XCTAssertTrue(names.contains("nested"))
    }

    func testWildcardCopyMoveAndVerification() throws {
        let srcDir = (tempRoot as NSString).appendingPathComponent("src")
        let dstDir = (tempRoot as NSString).appendingPathComponent("dst")
        try FileManager.default.createDirectory(atPath: srcDir, withIntermediateDirectories: true)

        let fileA = (srcDir as NSString).appendingPathComponent("report.txt")
        let fileB = (srcDir as NSString).appendingPathComponent("notes.md")
        try "Hello Total Commander".write(toFile: fileA, atomically: true, encoding: .utf8)
        try "# Markdown Notes".write(toFile: fileB, atomically: true, encoding: .utf8)

        let opts = FileOperationOptions(
            targetMask: "*.bak",
            overwritePolicy: .overwriteAll,
            preserveTimestamps: true,
            preservePermissions: true,
            verifyAfterCopy: true
        )
        let copied = try FileSystemEngine.copyOrMoveItems(
            sources: [fileA, fileB],
            toDestinationDirectory: dstDir,
            isMove: false,
            options: opts
        )
        XCTAssertEqual(copied.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: (dstDir as NSString).appendingPathComponent("report.bak")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: (dstDir as NSString).appendingPathComponent("notes.bak")))
    }

    func testDescriptionCommentsAndAttributes() throws {
        let file = (tempRoot as NSString).appendingPathComponent("sample file.txt")
        try "Sample content".write(toFile: file, atomically: true, encoding: .utf8)

        try FileSystemEngine.setDescriptionComment("Important project file", forFileName: "sample file.txt", inDirectory: tempRoot)
        let map = FileSystemEngine.loadDescriptionMap(inDirectory: tempRoot)
        XCTAssertEqual(map["sample file.txt"], "Important project file")

        let req = AttributeChangeRequest(posixPermissions: 0o755)
        try FileSystemEngine.changeAttributes(forPaths: [file], request: req)
        let inspected = FileSystemEngine.inspectFileItem(atPath: file)
        XCTAssertEqual(inspected?.octalPermissionsString, "755")
        XCTAssertTrue(inspected?.isExecutable ?? false)
    }

    func testBranchViewAndRecursiveSize() throws {
        let sub = (tempRoot as NSString).appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        let f1 = (tempRoot as NSString).appendingPathComponent("root.txt")
        let f2 = (sub as NSString).appendingPathComponent("deep.txt")
        try Data(repeating: 0x41, count: 1000).write(to: URL(fileURLWithPath: f1))
        try Data(repeating: 0x42, count: 2500).write(to: URL(fileURLWithPath: f2))

        let totalSize = FileSystemEngine.calculateDirectorySize(at: tempRoot)
        XCTAssertEqual(totalSize, 3500)

        let branchItems = FileSystemEngine.listBranchView(at: tempRoot, showHidden: false)
        let relPaths = Set(branchItems.compactMap { $0.relativeDisplayPath })
        XCTAssertTrue(relPaths.contains("root.txt"))
        XCTAssertTrue(relPaths.contains("a/b/c/deep.txt"))
    }

    // MARK: - 2. ArchiveEngine Tests (Pack, List Virtual Directory, Extract, Test Integrity)

    func testZipAndTarGzArchiveLifecycle() throws {
        let srcDir = (tempRoot as NSString).appendingPathComponent("to_pack")
        let subDir = (srcDir as NSString).appendingPathComponent("subfolder")
        try FileManager.default.createDirectory(atPath: subDir, withIntermediateDirectories: true)

        let f1 = (srcDir as NSString).appendingPathComponent("hello.txt")
        let f2 = (subDir as NSString).appendingPathComponent("nested.txt")
        try "Hello ZIP World".write(toFile: f1, atomically: true, encoding: .utf8)
        try "Nested Archive Content".write(toFile: f2, atomically: true, encoding: .utf8)

        let zipPath = (tempRoot as NSString).appendingPathComponent("bundle.zip")
        try ArchiveEngine.packFiles(
            sourcePaths: [f1, subDir],
            toArchivePath: zipPath,
            options: PackOptions(format: .zip, compressionLevel: 6)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: zipPath))

        let testRes = ArchiveEngine.testArchive(atPath: zipPath)
        XCTAssertTrue(testRes.isValid)

        let rootEntries = try ArchiveEngine.listArchiveDirectory(archivePath: zipPath, internalDirectory: "")
        let rootNames = Set(rootEntries.map { $0.name })
        XCTAssertTrue(rootNames.contains(".."))
        XCTAssertTrue(rootNames.contains("hello.txt"))
        XCTAssertTrue(rootNames.contains("subfolder"))

        let subEntries = try ArchiveEngine.listArchiveDirectory(archivePath: zipPath, internalDirectory: "subfolder")
        XCTAssertTrue(subEntries.contains(where: { $0.name == "nested.txt" }))

        let unpackDir = (tempRoot as NSString).appendingPathComponent("unpacked")
        try ArchiveEngine.unpackArchive(archivePath: zipPath, toDirectory: unpackDir)
        let extractedNested = (unpackDir as NSString).appendingPathComponent("subfolder/nested.txt")
        XCTAssertEqual(try String(contentsOfFile: extractedNested, encoding: .utf8), "Nested Archive Content")
    }

    // MARK: - 3. Multi-Rename Tool Engine Tests (Masks, Slices, Counter, Regex, Two-Phase Execute & Undo)

    func testMultiRenameMasksAndUndo() throws {
        let f1 = (tempRoot as NSString).appendingPathComponent("Photo_Vacation_One.JPG")
        let f2 = (tempRoot as NSString).appendingPathComponent("Photo_Vacation_Two.JPG")
        try "img1".write(toFile: f1, atomically: true, encoding: .utf8)
        try "img2".write(toFile: f2, atomically: true, encoding: .utf8)

        let items = try FileSystemEngine.listDirectory(at: tempRoot, showHidden: false, includeParentEntry: false)
            .sorted { $0.name < $1.name }

        let config = MultiRenameConfig(
            nameMask: "[N1-5]_[C]",
            extensionMask: "[E]",
            searchFor: "Photo",
            replaceWith: "shot",
            caseMode: .allLowercase,
            counterStart: 10,
            counterStep: 5,
            counterDigits: 3
        )

        let preview = MultiRenameEngine.generatePreview(items: items, config: config)
        XCTAssertEqual(preview.count, 2)
        XCTAssertEqual(preview[0].proposedName, "shot_010.jpg")
        XCTAssertEqual(preview[1].proposedName, "shot_015.jpg")
        XCTAssertFalse(preview[0].hasConflict)

        let batch = try MultiRenameEngine.executeRename(previewRows: preview)
        XCTAssertTrue(FileManager.default.fileExists(atPath: (tempRoot as NSString).appendingPathComponent("shot_010.jpg")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: (tempRoot as NSString).appendingPathComponent("shot_015.jpg")))

        try MultiRenameEngine.undoRename(batch: batch)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f2))
    }

    // MARK: - 4. Checksum, Split/Combine, and Encode/Decode Tests

    func testChecksumsSplitCombineAndEncodeDecode() throws {
        let originalFile = (tempRoot as NSString).appendingPathComponent("payload.bin")
        var payloadBytes = Data()
        for i in 0..<2500 {
            payloadBytes.append(UInt8(i & 0xFF))
        }
        try payloadBytes.write(to: URL(fileURLWithPath: originalFile))

        // 1. Checksum create & verify
        let manifests = try ChecksumEngine.createChecksumManifest(forFiles: [originalFile], kind: .sha256)
        XCTAssertEqual(manifests.count, 1)
        let verified = try ChecksumEngine.verifyChecksumManifest(atPath: manifests[0])
        XCTAssertEqual(verified.count, 1)
        XCTAssertEqual(verified[0].status, .ok)

        // 2. Split & Combine with CRC32 verification
        let splitDir = (tempRoot as NSString).appendingPathComponent("split_parts")
        let combineDir = (tempRoot as NSString).appendingPathComponent("combined_out")
        let parts = try SplitCombineEngine.splitFile(atPath: originalFile, toDirectory: splitDir, bytesPerPart: 600)
        XCTAssertEqual(parts.count, 6) // 5 parts (.001..005) + 1 .crc file

        let combineRes = try SplitCombineEngine.combineFiles(startingFromPath: parts[0], toDirectory: combineDir)
        XCTAssertTrue(combineRes.crcVerified)
        XCTAssertEqual(combineRes.totalBytes, 2500)
        let reconstructed = try Data(contentsOf: URL(fileURLWithPath: combineRes.outputFilePath))
        XCTAssertEqual(reconstructed, payloadBytes)

        // 3. Encode & Decode (Base64, UUEncode, XXEncode)
        for fmt in EncodingFormat.allCases {
            let encDir = (tempRoot as NSString).appendingPathComponent("enc_\(fmt.rawValue)")
            let decDir = (tempRoot as NSString).appendingPathComponent("dec_\(fmt.rawValue)")
            let encodedPath = try EncodeDecodeEngine.encodeFile(atPath: originalFile, toDirectory: encDir, format: fmt)
            let decodedPath = try EncodeDecodeEngine.decodeFile(atPath: encodedPath, toDirectory: decDir)
            let roundtrip = try Data(contentsOf: URL(fileURLWithPath: decodedPath))
            XCTAssertEqual(roundtrip, payloadBytes, "Roundtrip failed for \(fmt.rawValue)")
        }
    }

    // MARK: - 5. Find Files & Duplicate Finder Tests

    func testFindFilesAndDuplicates() throws {
        let d1 = (tempRoot as NSString).appendingPathComponent("dir1")
        let d2 = (tempRoot as NSString).appendingPathComponent("dir2")
        try FileManager.default.createDirectory(atPath: d1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: d2, withIntermediateDirectories: true)

        let f1 = (d1 as NSString).appendingPathComponent("dup.txt")
        let f2 = (d2 as NSString).appendingPathComponent("dup.txt")
        let f3 = (d2 as NSString).appendingPathComponent("unique.swift")
        try "Identical duplicate payload".write(toFile: f1, atomically: true, encoding: .utf8)
        try "Identical duplicate payload".write(toFile: f2, atomically: true, encoding: .utf8)
        try "public struct SwiftCode {}".write(toFile: f3, atomically: true, encoding: .utf8)

        // Search by content text
        let textQuery = FindFilesQuery(searchForMask: "*.swift", searchInPaths: [tempRoot], findText: "SwiftCode")
        let textRes = FindFilesEngine.search(query: textQuery)
        XCTAssertEqual(textRes.matchedItems.count, 1)
        XCTAssertEqual(textRes.matchedItems.first?.name, "unique.swift")

        // Search for duplicates by SHA-256 content
        let dupQuery = FindFilesQuery(
            searchForMask: "*",
            searchInPaths: [tempRoot],
            findDuplicates: true,
            duplicatesSameName: true,
            duplicatesSameSize: true,
            duplicatesSameContent: true
        )
        let dupRes = FindFilesEngine.search(query: dupQuery)
        XCTAssertEqual(dupRes.duplicateGroups.count, 1)
        XCTAssertEqual(dupRes.duplicateGroups[0].count, 2)
    }

    // MARK: - 6. Synchronize Directories & Compare By Content Tests

    func testSynchronizeDirectoriesAndCompareByContent() throws {
        let leftDir = (tempRoot as NSString).appendingPathComponent("sync_left")
        let rightDir = (tempRoot as NSString).appendingPathComponent("sync_right")
        try FileManager.default.createDirectory(atPath: leftDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: rightDir, withIntermediateDirectories: true)

        let lOnly = (leftDir as NSString).appendingPathComponent("only_left.txt")
        let rOnly = (rightDir as NSString).appendingPathComponent("only_right.txt")
        try "Left file".write(toFile: lOnly, atomically: true, encoding: .utf8)
        try "Right file".write(toFile: rOnly, atomically: true, encoding: .utf8)

        let entries = DirectorySyncEngine.compareDirectories(leftRoot: leftDir, rightRoot: rightDir)
        XCTAssertEqual(entries.count, 2)

        let syncResult = try DirectorySyncEngine.executeSync(entries: entries, leftRoot: leftDir, rightRoot: rightDir)
        XCTAssertEqual(syncResult.copiedLeftToRight, 1)
        XCTAssertEqual(syncResult.copiedRightToLeft, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: (rightDir as NSString).appendingPathComponent("only_left.txt")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: (leftDir as NSString).appendingPathComponent("only_right.txt")))

        // Compare by Content
        let diffReport = CompareByContentEngine.compareTextStrings(
            leftText: "line 1\nline 2 old\nline 3",
            rightText: "line 1\nline 2 new\nline 3"
        )
        XCTAssertFalse(diffReport.areIdentical)
        XCTAssertEqual(diffReport.differenceRowIndices.count, 1)
        XCTAssertEqual(diffReport.rows[1].kind, .modified)
    }
}

extension CZCommanderCoreTests {
    // MARK: - 7. Lister, DiskSpaceAnalyzer, Properties Inspector, Exporter & Persistence Tests

    func testListerHexBinaryAndDiskAnalyzer() throws {
        let f = (tempRoot as NSString).appendingPathComponent("binary_sample.dat")
        let sample = Data("Hello Total Commander M-Series!\nLine 2".utf8)
        try sample.write(to: URL(fileURLWithPath: f))

        let (loaded, totalSize) = try ListerEngine.loadFilePreviewData(atPath: f)
        XCTAssertEqual(totalSize, Int64(sample.count))
        let hexRows = ListerEngine.formatHexDumpRows(data: loaded)
        XCTAssertGreaterThanOrEqual(hexRows.count, 2)
        XCTAssertEqual(hexRows[0].offsetHex, "00000000")

        let binDump = ListerEngine.formatBinaryDump(data: loaded, width: 16)
        XCTAssertTrue(binDump.contains("Hello Total Comm"))

        let space = try DiskSpaceAnalyzerEngine.analyzeDirectory(at: tempRoot)
        XCTAssertEqual(space.totalBytes, Int64(sample.count))
        XCTAssertEqual(space.entries.count, 1)

        guard let item = FileSystemEngine.inspectFileItem(atPath: f) else {
            XCTFail("Failed to inspect file")
            return
        }
        let props = FilePropertiesInspectorEngine.inspectDetailedProperties(for: item, computeHashes: true)
        XCTAssertEqual(props.totalRecursiveBytes, Int64(sample.count))
        XCTAssertNotEqual(props.sha256, "—")

        let csvExport = FileListExporterEngine.formatFileList(items: [item], directoryPath: tempRoot, format: .csv)
        XCTAssertTrue(csvExport.contains("binary_sample.dat"))

        let configPath = (tempRoot as NSString).appendingPathComponent("test_wincmd.json")
        let savedCfg = CommanderSavedConfiguration(themeID: .nortonClassicBlue, fontSize: 14.0)
        try PersistenceManager.saveConfiguration(savedCfg, toPath: configPath)
        let loadedCfg = PersistenceManager.loadConfiguration(fromPath: configPath)
        XCTAssertEqual(loadedCfg?.themeID, .nortonClassicBlue)
        XCTAssertEqual(loadedCfg?.fontSize, 14.0)
    }

    @MainActor
    func testCommanderViewModelDualPaneOperations() throws {
        let leftDir = (tempRoot as NSString).appendingPathComponent("pane_left")
        let rightDir = (tempRoot as NSString).appendingPathComponent("pane_right")
        try FileManager.default.createDirectory(atPath: leftDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: rightDir, withIntermediateDirectories: true)

        try "Alpha".write(toFile: (leftDir as NSString).appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        try "Beta".write(toFile: (leftDir as NSString).appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let vm = CommanderViewModel(leftInitialPath: leftDir, rightInitialPath: rightDir)
        vm.leftPanel.navigateTo(path: leftDir)
        vm.rightPanel.navigateTo(path: rightDir)

        XCTAssertEqual(vm.activePanel.displayedItems.count, 3) // .., a.swift, b.txt
        vm.activePanel.selectGroup(pattern: "*.swift")
        XCTAssertEqual(vm.activePanel.selectedItemsOnly.count, 1)
        XCTAssertEqual(vm.activePanel.selectedItemsOnly.first?.name, "a.swift")

        vm.activePanel.invertSelection()
        XCTAssertEqual(vm.activePanel.selectedItemsOnly.count, 1)
        XCTAssertEqual(vm.activePanel.selectedItemsOnly.first?.name, "b.txt")

        vm.activePanel.moveCursor(by: 1)
        XCTAssertEqual(vm.activePanel.cursorIndex, 1)
        vm.activePanel.moveCursor(by: 1)
        XCTAssertEqual(vm.activePanel.cursorIndex, 2)
        vm.activePanel.moveCursor(by: -1)
        XCTAssertEqual(vm.activePanel.cursorIndex, 1)
    }
}

// MARK: - Total Commander style folder tab locking

extension CZCommanderCoreTests {
    private func makeDirs(_ names: [String]) throws -> [String] {
        try names.map { name in
            let p = (tempRoot as NSString).appendingPathComponent(name)
            try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
            return (p as NSString).standardizingPath
        }
    }

    @MainActor func testLockedTabOpensNewTabOnDirectoryChange() throws {
        let dirs = try makeDirs(["A", "B"])
        let panel = PanelController(side: .left, initialPath: dirs[0])
        panel.setTabLock(at: 0, to: .locked)
        panel.navigateTo(path: dirs[1])
        XCTAssertEqual(panel.tabs.count, 2)
        XCTAssertEqual(panel.tabs[0].currentPath, dirs[0])
        XCTAssertEqual(panel.activeTab.currentPath, dirs[1])
        XCTAssertEqual(panel.tabs[0].displayTitle, "* A")
    }

    @MainActor func testDirChangesAllowedTabReturnsToLockedFolderOnReselect() throws {
        let dirs = try makeDirs(["Home", "Other", "Home/Sub"])
        let panel = PanelController(side: .left, initialPath: dirs[0])
        panel.setTabLock(at: 0, to: .lockedDirChangesAllowed)
        panel.navigateTo(path: dirs[2])
        XCTAssertEqual(panel.tabs.count, 1, "directory changes are allowed in place")
        XCTAssertTrue(panel.activeTab.isAwayFromLockedBase)
        XCTAssertEqual(panel.activeTab.displayTitle, "! Home")

        panel.addNewTab(atPath: dirs[1])
        XCTAssertEqual(panel.activeTabIndex, 1)
        panel.selectTab(at: 0)
        XCTAssertEqual(panel.activeTab.currentPath, dirs[0], "re-selecting jumps back to the locked folder")
        XCTAssertEqual(panel.activeTab.displayTitle, "* Home")

        // Clicking the already active tab also returns
        panel.navigateTo(path: dirs[2])
        panel.selectTab(at: 0)
        XCTAssertEqual(panel.activeTab.currentPath, dirs[0])
    }

    @MainActor func testCloseOtherTabsKeepsLockedTabs() throws {
        let dirs = try makeDirs(["T1", "T2", "T3"])
        let panel = PanelController(side: .left, initialPath: dirs[0])
        panel.setTabLock(at: 0, to: .locked)
        panel.addNewTab(atPath: dirs[1])
        panel.addNewTab(atPath: dirs[2])
        panel.addNewTab(atPath: dirs[2])
        panel.closeDuplicateTabs()
        XCTAssertEqual(panel.tabs.count, 3)
        panel.closeOtherTabs(keeping: 2)
        XCTAssertEqual(panel.tabs.map(\.currentPath), [dirs[0], dirs[2]])
        XCTAssertEqual(panel.activeTab.currentPath, dirs[2])
        panel.closeTab(at: 0)
        XCTAssertEqual(panel.tabs.count, 2, "locked tab is not closed without force")
        panel.closeTab(at: 0, force: true)
        XCTAssertEqual(panel.tabs.count, 1)
    }
}

// MARK: - Toolbar migration (only Full / Thumbnails views)

extension CZCommanderCoreTests {
    @MainActor func testToolbarMigrationReplacesViewModeButtons() {
        let old = [
            ButtonBarItem(title: "Reread (F2)", iconName: "arrow.clockwise", command: "cm_RereadSource"),
            ButtonBarItem(title: "Brief", iconName: "list.bullet", command: "cm_SrcBrief"),
            ButtonBarItem(title: "Full", iconName: "tablecells", command: "cm_SrcFull"),
            ButtonBarItem(title: "Branch (Ctrl+B)", iconName: "list.bullet.indent", command: "cm_DirBranch"),
            ButtonBarItem(title: "Tree (Ctrl+F8)", iconName: "sidebar.left", command: "cm_SwitchSeparateTree")
        ]
        let migrated = CommanderViewModel.migrateToolbar(old).map(\.command)
        XCTAssertEqual(migrated, ["cm_RereadSource", "cm_SwitchView", "cm_SwitchHidSys"], "Tree and legacy view buttons are retired")
        XCTAssertEqual(CommanderViewModel.migrateToolbar(CommanderViewModel.migrateToolbar(old)).map(\.command), migrated)
        XCTAssertEqual(PanelViewMode.brief.normalizedForUI, .full)
        XCTAssertEqual(PanelViewMode.thumbnails.normalizedForUI, .thumbnails)
    }
}

// MARK: - Cleanup commands

extension CZCommanderCoreTests {
    @MainActor func testCleanupCommandsOpenTheirDialogs() {
        let vm = CommanderViewModel.shared
        vm.executeInternalCommand("cm_Cleanup")
        XCTAssertEqual(vm.activeSheet?.id, "cleanup")
        vm.executeInternalCommand("cm_Startup")
        XCTAssertEqual(vm.activeSheet?.id, "startup")
        vm.executeInternalCommand("cm_EmptyTrash")
        XCTAssertEqual(vm.activeSheet?.id, "emptytrash", "Empty Trash asks before deleting anything")
        vm.activeSheet = nil
    }
}

// MARK: - Delete confirmation + right-click selection

extension CZCommanderCoreTests {
    @MainActor func testF8AsksForConfirmationBeforeDeleting() throws {
        let vm = CommanderViewModel.shared
        let file = (tempRoot as NSString).appendingPathComponent("victim.txt")
        try "x".write(toFile: file, atomically: true, encoding: .utf8)
        vm.activeSide = .left
        vm.leftPanel.navigateTo(path: tempRoot)
        vm.leftPanel.reload()
        guard let row = vm.leftPanel.displayedItems.firstIndex(where: { $0.name == "victim.txt" }) else {
            return XCTFail("file not listed")
        }
        vm.leftPanel.setCursor(to: row, scrollIntoView: false)
        vm.triggerF8Delete(permanent: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file), "F8 must not delete before confirmation")
        guard case .deleteConfirm(let items, let permanent, _)? = vm.activeSheet else {
            return XCTFail("expected delete confirmation sheet")
        }
        XCTAssertTrue(permanent)
        vm.activeSheet = nil
        vm.performDelete(items: items, permanent: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file))

        let other = (tempRoot as NSString).appendingPathComponent("keep.txt")
        try "y".write(toFile: other, atomically: true, encoding: .utf8)
        vm.leftPanel.reload()
        let id = try XCTUnwrap(vm.leftPanel.displayedItems.first(where: { $0.name == "keep.txt" })?.id)
        vm.leftPanel.setSelection(ofItemID: id, selected: true)
        XCTAssertTrue(vm.leftPanel.selectedItemIDs.contains(id))
        vm.leftPanel.setSelection(ofItemID: id, selected: false)
        XCTAssertFalse(vm.leftPanel.selectedItemIDs.contains(id))
    }
}

// MARK: - Update check version comparison

extension CZCommanderCoreTests {
    func testAppVersionComparison() {
        XCTAssertTrue(AppVersion.isNewer("v1.0.1", than: "1.0.0"))
        XCTAssertTrue(AppVersion.isNewer("1.10.0", than: "1.9.9"))
        XCTAssertTrue(AppVersion.isNewer("2.0", than: "1.99.99"))
        XCTAssertFalse(AppVersion.isNewer("v1.0.0", than: "1.0.0"))
        XCTAssertFalse(AppVersion.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(AppVersion.isNewer("0.9.9", than: "1.0.0"))
        XCTAssertEqual(AppVersion.components("v1.2.3-beta"), [1, 2, 3])
    }
}

// MARK: - Human-readable sizes

extension CZCommanderCoreTests {
    func testByteCountUsesLargestUnit() {
        XCTAssertEqual(FileItem.formatByteCount(0), "0 B")
        XCTAssertEqual(FileItem.formatByteCount(1023), "1023 B")
        XCTAssertEqual(FileItem.formatByteCount(1536), "1.5 KB")
        XCTAssertEqual(FileItem.formatByteCount(5 * 1_048_576 + 400_000), "5.4 MB")
        XCTAssertEqual(FileItem.formatByteCount(3 * 1_073_741_824), "3.00 GB")
        XCTAssertEqual(FileItem.formatByteCount(2 * 1_099_511_627_776 + 1_099_511_627_776 / 4), "2.25 TB")
        XCTAssertEqual(FileItem.formatByteCount(1536, format: .bytes), "1.5 KB", "one style everywhere")
    }
}
