import SwiftUI
import CZCommanderCore

// MARK: - 1. F5 Copy / F6 Move Dialog

public struct CopyMoveSheetView: View {
    @ObservedObject var viewModel: CommanderViewModel
    public let sources: [FileItem]
    @State private var destinationDir: String
    public let isMove: Bool
    @State private var targetMask: String = "*.*"
    @State private var overwritePolicy: OverwritePolicy = .ask
    @State private var preserveTimestamps: Bool = true
    @State private var preservePermissions: Bool = true
    @State private var verifyAfterCopy: Bool = false
    @State private var errorMessage: String? = nil
    private func dismiss() { CommanderDialog.close(viewModel) }


    public init(viewModel: CommanderViewModel, sources: [FileItem], destinationDir: String, isMove: Bool) {
        self.viewModel = viewModel
        self.sources = sources
        self._destinationDir = State(initialValue: destinationDir)
        self.isMove = isMove
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: isMove ? "folder.badge.gearshape" : "doc.on.doc.fill")
                    .font(.system(size: 18, weight: .bold))
                Text(
                    isMove
                        ? "Move / Rename (F6) — \(sources.count) item(s)"
                        : "Copy (F5) — \(sources.count) item(s)"
                )
                .font(.headline)
            }
            // Counted while the dialog is open, like Total Commander.
            TransferTotalsLine(localPaths: sources.filter { $0.archiveContainerPath == nil }.map(\.fullPath))

            VStack(alignment: .leading, spacing: 6) {
                Text("Destination directory:")
                    .font(.subheadline)
                TextField("Destination path", text: $destinationDir)
                    .textFieldStyle(SquareTextFieldStyle())
                    .font(.system(size: 12, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Target filename mask (e.g. *.*, *.bak, copy_*.*):")
                    .font(.subheadline)
                TextField("*.*", text: $targetMask)
                    .textFieldStyle(SquareTextFieldStyle())
                    .font(.system(size: 12, design: .monospaced))
            }

            SquarePicker("Overwrite mode:", selection: $overwritePolicy, options: OverwritePolicy.allCases.map { policy in (value: policy, title: policy.displayName) })

            HStack(spacing: 16) {
                Toggle("Preserve timestamps", isOn: $preserveTimestamps)
                Toggle("Preserve permissions", isOn: $preservePermissions)
                if !isMove {
                    Toggle("Verify CRC32 after copy", isOn: $verifyAfterCopy)
                }
            }

            if let err = errorMessage {
                Text(err)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            Divider()

            HStack {
                Button("F2 Queue (Background)") {
                    let opts = FileOperationOptions(
                        targetMask: targetMask,
                        overwritePolicy: overwritePolicy,
                        preserveTimestamps: preserveTimestamps,
                        preservePermissions: preservePermissions,
                        verifyAfterCopy: verifyAfterCopy
                    )
                    viewModel.enqueueTransferJob(
                        sources: sources.map { $0.fullPath },
                        destination: destinationDir,
                        isMove: isMove,
                        options: opts
                    )
                    dismiss()
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Start (OK)") {
                    executeOperation()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private func executeOperation() {
        do {
            // Check if source is inside an archive (extract out of archive!)
            if case .archive(let archivePath, _) = viewModel.activePanel.activeTab.vfsMode {
                let internalPaths = sources.compactMap { $0.archiveInternalPath }
                dismiss()
                FileOperationManager.shared.extract(from: archivePath, entries: internalPaths, to: destinationDir)
                return
            } else if case .archive(let targetArchivePath, _) = viewModel.inactivePanel.activeTab.vfsMode {
                // Target panel is inside an archive -> Pack into existing archive!
                try ArchiveEngine.addFilesToArchive(
                    sourcePaths: sources.map { $0.fullPath },
                    archivePath: targetArchivePath
                )
            } else {
                let opts = FileOperationOptions(
                    targetMask: targetMask,
                    overwritePolicy: overwritePolicy,
                    preserveTimestamps: preserveTimestamps,
                    preservePermissions: preservePermissions,
                    verifyAfterCopy: verifyAfterCopy
                )
                // Runs in the background with the Total Commander style progress dialog.
                dismiss()
                if isMove {
                    FileOperationManager.shared.move(sources.map { $0.fullPath }, to: destinationDir, options: opts)
                } else {
                    FileOperationManager.shared.copy(sources.map { $0.fullPath }, to: destinationDir, options: opts)
                }
                return
            }
            viewModel.activePanel.activeTab.selectedItemIDs.removeAll()
            viewModel.leftPanel.reload()
            viewModel.rightPanel.reload()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 2. F7 Create Directory Dialog

public struct MkDirSheetView: View {
    @ObservedObject var viewModel: CommanderViewModel
    public let baseDir: String
    @State private var folderExpression: String = "NewFolder"
    @State private var errorMessage: String? = nil
    private func dismiss() { CommanderDialog.close(viewModel) }


    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 18, weight: .bold))
                Text("Create New Directory (F7)")
                    .font(.headline)
            }

            Text("Create multiple or nested folders: dir1|dir2|nested/dir3")
            .font(.caption)
            .foregroundColor(.secondary)

            TextField("Folder name", text: $folderExpression)
                .textFieldStyle(SquareTextFieldStyle())
                .font(.system(size: 13, design: .monospaced))

            HStack(spacing: 6) {
                Text("Insert placeholder:")
                    .font(.caption)
                ForEach(["[YMD]", "[hms]", "[Y]-[M]-[D]"], id: \.self) { token in
                    Button(token) {
                        folderExpression += token
                    }
                    .controlSize(.small)
                }
            }

            if let err = errorMessage {
                Text(err).foregroundColor(.red).font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create (OK)") {
                    if let loc = DropboxLocation(fullPath: baseDir) {
                        let name = folderExpression.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty, !name.contains("/") else { errorMessage = "Enter a folder name."; return }
                        let panel = viewModel.activePanel
                        Task {
                            do {
                                try await DropboxClient.shared.createFolder(loc.appending(name))
                                panel.refreshDropbox()
                                panel.reload(selectingItemNamed: name)
                                dismiss()
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                        return
                    }
                    do {
                        let created = try FileSystemEngine.createDirectories(expression: folderExpression, in: baseDir)
                        let firstName = created.first.map { ($0 as NSString).lastPathComponent }
                        viewModel.activePanel.reload(selectingItemNamed: firstName)
                        viewModel.inactivePanel.reload()
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - 3. Alt+F5 Pack Files Dialog

public struct PackFilesSheetView: View {
    @ObservedObject var viewModel: CommanderViewModel
    public let sources: [FileItem]
    @State private var archivePath: String
    @State private var format: ArchiveFormat = .zip
    @State private var compressionLevel: Double = 6
    @State private var includeParentPaths: Bool = false
    @State private var recurseSubdirectories: Bool = true
    @State private var moveToArchive: Bool = false
    @State private var separateArchivePerItem: Bool = false
    @State private var errorMessage: String? = nil
    private func dismiss() { CommanderDialog.close(viewModel) }


    public init(viewModel: CommanderViewModel, sources: [FileItem], destinationDir: String) {
        self.viewModel = viewModel
        self.sources = sources
        let baseName = sources.count == 1 ? sources[0].stem : ((sources.first?.fullPath as NSString?)?.deletingLastPathComponent as NSString?)?.lastPathComponent ?? "archive"
        let initialArchive = (destinationDir as NSString).appendingPathComponent("\(baseName).zip")
        self._archivePath = State(initialValue: initialArchive)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 18, weight: .bold))
                Text("Pack Files (Alt+F5) — \(sources.count) item(s)")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Target archive path:")
                    .font(.subheadline)
                TextField("Archive path", text: $archivePath)
                    .textFieldStyle(SquareTextFieldStyle())
                    .font(.system(size: 12, design: .monospaced))
            }

            SquarePicker("Archive format:", selection: $format, options: ArchiveFormat.allCases.map { fmt in (value: fmt, title: fmt.rawValue.uppercased()) }, kind: .segmented)
            .onChange(of: format) { _, newFmt in
                let dir = (archivePath as NSString).deletingLastPathComponent
                let name = ((archivePath as NSString).lastPathComponent as NSString).deletingPathExtension
                    .replacingOccurrences(of: ".tar", with: "")
                archivePath = (dir as NSString).appendingPathComponent("\(name).\(newFmt.fileExtension)")
            }

            HStack {
                Text("Compression level (\(Int(compressionLevel))):")
                Slider(value: $compressionLevel, in: 0...9, step: 1)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Recurse subdirectories", isOn: $recurseSubdirectories)
                Toggle("Also pack pathnames", isOn: $includeParentPaths)
                Toggle("Move to archive (delete originals)", isOn: $moveToArchive)
                Toggle("Create separate archives, one per selected item", isOn: $separateArchivePerItem)
            }

            if let err = errorMessage {
                Text(err).foregroundColor(.red).font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Pack (OK)") {
                    do {
                        let opts = PackOptions(
                            format: format,
                            compressionLevel: Int(compressionLevel),
                            includeParentPaths: includeParentPaths,
                            recurseSubdirectories: recurseSubdirectories,
                            moveToArchive: moveToArchive,
                            separateArchivePerItem: separateArchivePerItem
                        )
                        _ = try ArchiveEngine.packFiles(
                            sourcePaths: sources.map { $0.fullPath },
                            toArchivePath: archivePath,
                            options: opts
                        )
                        viewModel.leftPanel.reload()
                        viewModel.rightPanel.reload()
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

// MARK: - 4. Alt+F9 Unpack Files Dialog

public struct UnpackFilesSheetView: View {
    @ObservedObject var viewModel: CommanderViewModel
    public let archives: [FileItem]
    @State private var destinationDir: String
    @State private var unpackEachToSubdir: Bool = false
    @State private var errorMessage: String? = nil
    private func dismiss() { CommanderDialog.close(viewModel) }


    public init(viewModel: CommanderViewModel, archives: [FileItem], destinationDir: String) {
        self.viewModel = viewModel
        self.archives = archives
        self._destinationDir = State(initialValue: destinationDir)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "shippingbox.and.arrow.backward.fill")
                    .font(.system(size: 18, weight: .bold))
                Text("Unpack Archives (Alt+F9) — \(archives.count)")
                    .font(.headline)
            }

            TextField("Destination directory", text: $destinationDir)
                .textFieldStyle(SquareTextFieldStyle())
                .font(.system(size: 12, design: .monospaced))

            Toggle(
                "Always unpack into a folder named after the archive",
                isOn: $unpackEachToSubdir
            )
            Text("Otherwise: archives with only folders at the top unpack as they are; archives with loose files at the top go into a folder named after the archive.")
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let err = errorMessage {
                Text(err).foregroundColor(.red).font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Unpack (OK)") {
                    dismiss()
                    FileOperationManager.shared.unpack(archives.map(\.fullPath), to: destinationDir,
                                                       alwaysFolder: unpackEachToSubdir)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

// MARK: - 5. Select / Unselect Group Dialog (+ / -)

public struct SelectGroupSheetView: View {
    @ObservedObject var viewModel: CommanderViewModel
    public let isSelect: Bool
    @State private var pattern: String = "*.*"
    @State private var includeDirectories: Bool = false
    private func dismiss() { CommanderDialog.close(viewModel) }


    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                isSelect
                    ? "Expand Selection (+)"
                    : "Shrink Selection (-)"
            )
            .font(.headline)

            TextField("*.swift;*.md | *Test*", text: $pattern)
                .textFieldStyle(SquareTextFieldStyle())
                .font(.system(size: 13, design: .monospaced))

            HStack(spacing: 6) {
                ForEach(["*.*", "*.swift;*.c;*.py", "*.zip;*.tar.gz", "*.png;*.jpg;*.pdf"], id: \.self) { preset in
                    Button(preset) { pattern = preset }
                        .controlSize(.small)
                }
            }

            Toggle("Also apply to directories", isOn: $includeDirectories)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") {
                    if isSelect {
                        viewModel.activePanel.selectGroup(pattern: pattern, includeDirectories: includeDirectories)
                    } else {
                        viewModel.activePanel.unselectGroup(pattern: pattern, includeDirectories: includeDirectories)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

// MARK: - 6. Change Attributes / Permissions / Timestamps Sheet

public struct ChangeAttributesSheetView: View {
    @ObservedObject var viewModel: CommanderViewModel
    public let items: [FileItem]

    @State private var changePermissions: Bool = true
    @State private var ownerRead: Bool = true
    @State private var ownerWrite: Bool = true
    @State private var ownerExec: Bool = false
    @State private var groupRead: Bool = true
    @State private var groupWrite: Bool = false
    @State private var groupExec: Bool = false
    @State private var otherRead: Bool = true
    @State private var otherWrite: Bool = false
    @State private var otherExec: Bool = false

    @State private var changeFlags: Bool = false
    @State private var isLockedFlag: Bool = false
    @State private var isHiddenFlag: Bool = false

    @State private var changeTimestamp: Bool = false
    @State private var modificationDate: Date = Date()
    @State private var tagColor: FinderTagColor = .none
    @State private var recurseSubdirectories: Bool = false
    private func dismiss() { CommanderDialog.close(viewModel) }


    private var computedPermMask: UInt16 {
        var m: UInt16 = 0
        if ownerRead { m |= 0o400 }
        if ownerWrite { m |= 0o200 }
        if ownerExec { m |= 0o100 }
        if groupRead { m |= 0o040 }
        if groupWrite { m |= 0o020 }
        if groupExec { m |= 0o010 }
        if otherRead { m |= 0o004 }
        if otherWrite { m |= 0o002 }
        if otherExec { m |= 0o001 }
        return m
    }

    public init(viewModel: CommanderViewModel, items: [FileItem]) {
        self.viewModel = viewModel
        self.items = items
        if let first = items.first {
            let p = first.posixPermissions
            _ownerRead = State(initialValue: (p & 0o400) != 0)
            _ownerWrite = State(initialValue: (p & 0o200) != 0)
            _ownerExec = State(initialValue: (p & 0o100) != 0)
            _groupRead = State(initialValue: (p & 0o040) != 0)
            _groupWrite = State(initialValue: (p & 0o020) != 0)
            _groupExec = State(initialValue: (p & 0o010) != 0)
            _otherRead = State(initialValue: (p & 0o004) != 0)
            _otherWrite = State(initialValue: (p & 0o002) != 0)
            _otherExec = State(initialValue: (p & 0o001) != 0)
            _isLockedFlag = State(initialValue: first.isLocked)
            _isHiddenFlag = State(initialValue: first.isHidden)
            _modificationDate = State(initialValue: first.modificationDate)
            _tagColor = State(initialValue: first.finderTagColor)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Change Attributes & Permissions (\(items.count) item(s))")
                .font(.headline)

            GroupBox(label: Toggle("POSIX Permissions (Octal: \(String(format: "%03o", computedPermMask)))", isOn: $changePermissions)) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Owner:").frame(width: 140, alignment: .leading)
                        Toggle("Read (r)", isOn: $ownerRead)
                        Toggle("Write (w)", isOn: $ownerWrite)
                        Toggle("Exec (x)", isOn: $ownerExec)
                    }
                    HStack {
                        Text("Group:").frame(width: 140, alignment: .leading)
                        Toggle("Read (r)", isOn: $groupRead)
                        Toggle("Write (w)", isOn: $groupWrite)
                        Toggle("Exec (x)", isOn: $groupExec)
                    }
                    HStack {
                        Text("Other:").frame(width: 140, alignment: .leading)
                        Toggle("Read (r)", isOn: $otherRead)
                        Toggle("Write (w)", isOn: $otherWrite)
                        Toggle("Exec (x)", isOn: $otherExec)
                    }
                }
                .padding(6)
                .disabled(!changePermissions)
            }

            GroupBox(label: Toggle("macOS Flags & Finder Tag", isOn: $changeFlags)) {
                HStack(spacing: 16) {
                    Toggle("Locked (Immutable)", isOn: $isLockedFlag)
                    Toggle("Hidden (UF_HIDDEN)", isOn: $isHiddenFlag)
                    SquarePicker("Tag:", selection: $tagColor, options: FinderTagColor.allCases.map { c in (value: c, title: c.displayName) })
                    .frame(width: 150)
                }
                .padding(6)
                .disabled(!changeFlags)
            }

            GroupBox(label: Toggle("Change Modification Timestamp", isOn: $changeTimestamp)) {
                HStack {
                    DatePicker("", selection: $modificationDate)
                        .labelsHidden()
                    Button("Current Time") {
                        modificationDate = Date()
                    }
                }
                .padding(6)
                .disabled(!changeTimestamp)
            }

            Toggle("Recurse subdirectories", isOn: $recurseSubdirectories)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply (OK)") {
                    let req = AttributeChangeRequest(
                        posixPermissions: changePermissions ? computedPermMask : nil,
                        isLocked: changeFlags ? isLockedFlag : nil,
                        isHidden: changeFlags ? isHiddenFlag : nil,
                        modificationDate: changeTimestamp ? modificationDate : nil,
                        finderTagColor: changeFlags ? tagColor : nil,
                        recurseSubdirectories: recurseSubdirectories
                    )
                    try? FileSystemEngine.changeAttributes(forPaths: items.map { $0.fullPath }, request: req)
                    viewModel.leftPanel.reload()
                    viewModel.rightPanel.reload()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
    }
}

// MARK: - 7. Checksum Create & Verify Sheets, Split/Combine, Encode/Decode Sheets

public struct ChecksumCreateSheetView: View {
    @ObservedObject var viewModel: CommanderViewModel
    public let files: [FileItem]
    @State private var kind: ChecksumKind = .sha256
    @State private var separatePerFile: Bool = false
    private func dismiss() { CommanderDialog.close(viewModel) }


    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create Checksum File(s) (\(files.count) file(s))")
                .font(.headline)

            SquarePicker("Algorithm:", selection: $kind, options: ChecksumKind.allCases.map { k in (value: k, title: k.displayName) }, kind: .radio)

            Toggle("Create separate checksum file for each file", isOn: $separatePerFile)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("OK") {
                    _ = try? ChecksumEngine.createChecksumManifest(
                        forFiles: files.map { $0.fullPath },
                        kind: kind,
                        separateFilePerItem: separatePerFile
                    )
                    viewModel.leftPanel.reload()
                    viewModel.rightPanel.reload()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

public struct ChecksumVerifySheetView: View {
    @ObservedObject var viewModel: CommanderViewModel
    public let manifestPath: String
    @State private var rows: [ChecksumVerificationRow] = []
    private func dismiss() { CommanderDialog.close(viewModel) }


    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Verify Checksums — \((manifestPath as NSString).lastPathComponent)")
                .font(.headline)

            List(rows) { row in
                HStack {
                    Image(systemName: row.status == .ok ? "checkmark.seal.fill" : "xmark.octagon.fill")
                        .foregroundColor(row.status == .ok ? .green : .red)
                    Text(row.fileName)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .frame(width: 180, alignment: .leading)
                    Text(row.status.rawValue)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(row.status == .ok ? .green : .red)
                        .frame(width: 80)
                    Text(row.actualHash)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(minHeight: 260)

            HStack {
                let okCount = rows.filter { $0.status == .ok }.count
                Text("Result: \(okCount) / \(rows.count) OK")
                    .font(.subheadline)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 660, height: 420)
        .onAppear {
            rows = (try? ChecksumEngine.verifyChecksumManifest(atPath: manifestPath)) ?? []
        }
    }
}

public struct SplitCombineEncodeSheetViews {
    public struct SplitSheet: View {
        @ObservedObject var viewModel: CommanderViewModel
        public let file: FileItem
        @State var destinationDir: String
        @State private var bytesPerPart: Int = 1_457_664 // 1.44 MB default
        private func dismiss() { CommanderDialog.close(viewModel) }

        public var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                Text("Split File: \(file.name)")
                    .font(.headline)
                TextField("Target directory", text: $destinationDir)
                    .textFieldStyle(SquareTextFieldStyle())
                SquarePicker("Bytes per part:", selection: $bytesPerPart, options: [
                    (value: 102_400, title: "100 KB"),
                    (value: 1_457_664, title: "1.44 MB (Floppy)"),
                    (value: 10_485_760, title: "10 MB"),
                    (value: 104_857_600, title: "100 MB"),
                    (value: 734_003_200, title: "700 MB (CD-R)")
                ])
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                    Button("OK") {
                        _ = try? SplitCombineEngine.splitFile(atPath: file.fullPath, toDirectory: destinationDir, bytesPerPart: bytesPerPart)
                        viewModel.leftPanel.reload()
                        viewModel.rightPanel.reload()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 440)
        }
    }

    public struct CombineSheet: View {
        @ObservedObject var viewModel: CommanderViewModel
        public let partOrCRC: FileItem
        @State var destinationDir: String
        @State private var resultMessage: String? = nil
        private func dismiss() { CommanderDialog.close(viewModel) }

        public var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                Text("Combine Files: \(partOrCRC.name)")
                    .font(.headline)
                TextField("Target directory", text: $destinationDir)
                    .textFieldStyle(SquareTextFieldStyle())
                if let msg = resultMessage {
                    Text(msg).font(.caption).foregroundColor(.green)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                    Button("OK") {
                        if let res = try? SplitCombineEngine.combineFiles(startingFromPath: partOrCRC.fullPath, toDirectory: destinationDir) {
                            viewModel.statusBannerMessage = "Combined \(res.partsCombined) parts (\(res.totalBytes) B) — CRC32: \(res.actualCRC) (\(res.crcVerified ? "OK" : "MISMATCH"))"
                        }
                        viewModel.leftPanel.reload()
                        viewModel.rightPanel.reload()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 440)
        }
    }

    public struct EncodeSheet: View {
        @ObservedObject var viewModel: CommanderViewModel
        public let file: FileItem
        @State var destinationDir: String
        @State private var format: EncodingFormat = .mimeBase64
        private func dismiss() { CommanderDialog.close(viewModel) }

        public var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                Text("Encode File (MIME/UUE/XXE): \(file.name)")
                    .font(.headline)
                TextField("Target directory", text: $destinationDir)
                    .textFieldStyle(SquareTextFieldStyle())
                SquarePicker("Format:", selection: $format, options: EncodingFormat.allCases.map { f in (value: f, title: f.displayName) }, kind: .radio)
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                    Button("OK") {
                        _ = try? EncodeDecodeEngine.encodeFile(atPath: file.fullPath, toDirectory: destinationDir, format: format)
                        viewModel.leftPanel.reload()
                        viewModel.rightPanel.reload()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 440)
        }
    }

    public struct DecodeSheet: View {
        @ObservedObject var viewModel: CommanderViewModel
        public let file: FileItem
        @State var destinationDir: String
        private func dismiss() { CommanderDialog.close(viewModel) }

        public var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                Text("Decode File (B64/UUE/XXE): \(file.name)")
                    .font(.headline)
                TextField("Target directory", text: $destinationDir)
                    .textFieldStyle(SquareTextFieldStyle())
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                    Button("OK") {
                        _ = try? EncodeDecodeEngine.decodeFile(atPath: file.fullPath, toDirectory: destinationDir)
                        viewModel.leftPanel.reload()
                        viewModel.rightPanel.reload()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 440)
        }
    }
}
