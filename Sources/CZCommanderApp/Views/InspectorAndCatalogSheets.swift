import SwiftUI
import AppKit
import CZCommanderCore

// MARK: - 1. File Properties & Hash Inspector Sheet (Alt+Enter / Cmd+I)

public struct FilePropertiesSheetView: View {
    @ObservedObject var viewModel: CommanderViewModel
    public let item: FileItem
    @State private var props: DetailedFileProperties? = nil
    private func dismiss() { CommanderDialog.close(viewModel) }


    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 20, weight: .bold))
                Text("File / Folder Properties & Hash Inspector (Alt+Enter)")
                    .font(.headline)
            }

            if let p = props {
                GroupBox(label: Text("General Information")) {
                    VStack(alignment: .leading, spacing: 5) {
                        propRow("Name:", p.item.name)
                        propRow("Full Path:", p.item.fullPath)
                        propRow("File Type (magic):", p.fileTypeMagicDescription)
                        propRow(
                            "Size:",
                            "\(FileItem.formatByteCount(p.totalRecursiveBytes, format: .dynamicKMGT)) (\(FileItem.formatWithThousandsSeparator(p.totalRecursiveBytes)) B)"
                        )
                        if p.item.isDirectory {
                            propRow("Contents:", "\(p.recursiveFileCount) files, \(p.recursiveSubdirCount) directories")
                        }
                        propRow("Modified:", p.item.formattedModificationDate)
                        propRow("Permissions:", "\(p.item.permissionsString) (\(p.item.octalPermissionsString)) — \(p.item.ownerName):\(p.item.groupName)")
                        if let target = p.item.symlinkTarget {
                            propRow("Symlink Target:", target)
                        }
                    }
                    .padding(6)
                }

                if !p.item.isDirectory {
                    GroupBox(label: Text("Cryptographic Checksums (Apple Silicon CryptoKit)")) {
                        VStack(alignment: .leading, spacing: 6) {
                            hashRow("CRC32:", p.crc32)
                            hashRow("MD5:", p.md5)
                            hashRow("SHA-1:", p.sha1)
                            hashRow("SHA-256:", p.sha256)
                            hashRow("SHA-512:", p.sha512)
                        }
                        .padding(6)
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 200)
            }

            HStack {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.fullPath)])
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 680)
        .onAppear {
            let targetItem = item
            Task.detached(priority: .userInitiated) {
                let computed = FilePropertiesInspectorEngine.inspectDetailedProperties(for: targetItem)
                await MainActor.run {
                    self.props = computed
                }
            }
        }
    }

    private func propRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 140, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func hashRow(_ label: String, _ hash: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                .frame(width: 75, alignment: .leading)
            Text(hash)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hash, forType: .string)
            }
            .controlSize(.small)
        }
    }
}

// MARK: - 2. Export / Print File List Sheet

public struct ExportFileListSheetView: View {
    @ObservedObject var viewModel: CommanderViewModel
    public let items: [FileItem]
    public let directoryPath: String
    @State private var format: FileListExportFormat = .plainText
    @State private var outputFilePath: String = ""
    @State private var statusMessage: String = ""
    private func dismiss() { CommanderDialog.close(viewModel) }


    private var generatedContent: String {
        FileListExporterEngine.formatFileList(items: items, directoryPath: directoryPath, format: format)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export / Print File List (\(items.count) item(s))")
                .font(.headline)

            SquarePicker("Format:", selection: $format, options: FileListExportFormat.allCases.map { f in (value: f, title: f.displayName) }, kind: .segmented)
            .onChange(of: format) { _, newFmt in
                outputFilePath = (viewModel.inactivePanel.currentPath as NSString).appendingPathComponent("filelist.\(newFmt.rawValue)")
            }

            TextEditor(text: .constant(generatedContent))
                .font(.system(size: 11.5, design: .monospaced))
                .frame(minHeight: 260)

            HStack {
                Text("Save to file:")
                TextField("Output path", text: $outputFilePath)
                    .textFieldStyle(SquareTextFieldStyle())
                    .font(.system(size: 12, design: .monospaced))
            }

            HStack {
                if !statusMessage.isEmpty {
                    Text(statusMessage).foregroundColor(.green).font(.caption)
                }
                Spacer()
                Button("Copy to Clipboard") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(generatedContent, forType: .string)
                    statusMessage = "Copied to clipboard!"
                }
                Button("Save to File") {
                    try? generatedContent.write(toFile: outputFilePath, atomically: true, encoding: .utf8)
                    viewModel.leftPanel.reload()
                    viewModel.rightPanel.reload()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 500)
        .onAppear {
            outputFilePath = (viewModel.inactivePanel.currentPath as NSString).appendingPathComponent("filelist.\(format.rawValue)")
        }
    }
}

// MARK: - 3. Button Bar Customizer Sheet

public struct ButtonBarEditorSheetView: View {
    @ObservedObject var viewModel: CommanderViewModel
    @State private var newTitle: String = "Custom Tool"
    @State private var newIcon: String = "hammer.fill"
    @State private var newCommand: String = "cm_Properties"
    private func dismiss() { CommanderDialog.close(viewModel) }


    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Customize Button Bar")
                .font(.headline)

            List {
                ForEach(viewModel.buttonBarItems) { btn in
                    HStack {
                        Image(systemName: btn.iconName)
                            .frame(width: 24)
                        Text(btn.title)
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 160, alignment: .leading)
                        Text(btn.command)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(role: .destructive) {
                            viewModel.buttonBarItems.removeAll { $0.id == btn.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 240)

            GroupBox(label: Text("Add Button (cm_* internal commands)")) {
                HStack {
                    TextField("Title", text: $newTitle).textFieldStyle(SquareTextFieldStyle()).frame(width: 140)
                    TextField("SF Symbol", text: $newIcon).textFieldStyle(SquareTextFieldStyle()).frame(width: 130)
                    TextField("Internal command (e.g. cm_Properties, cm_FileSync)", text: $newCommand).textFieldStyle(SquareTextFieldStyle())
                    Button("Add") {
                        viewModel.buttonBarItems.append(
                            ButtonBarItem(title: newTitle, iconName: newIcon, command: newCommand)
                        )
                    }
                }
                .padding(6)
            }

            HStack {
                Spacer()
                Button("Save & Close") {
                    viewModel.saveCurrentConfiguration()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 660)
    }
}

// MARK: - 4. Full Disk Access Helper & Sheet

public enum FullDiskAccessHelper {
    public static func hasFullDiskAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let testPaths = [
            (home as NSString).appendingPathComponent("Library/Safari"),
            (home as NSString).appendingPathComponent(".Trash"),
            "/Library/Application Support/com.apple.TCC"
        ]
        for p in testPaths {
            if (try? FileManager.default.contentsOfDirectory(atPath: p)) != nil {
                return true
            }
        }
        return false
    }

    public static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    public static func requestRootFolderAccessViaOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Grant full drive access (select / or the Macintosh HD root)"
        panel.message = "Click 'Open' to unlock the whole file system once."
        panel.prompt = "Grant Full Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/")
        if panel.runModal() == .OK {
            for url in panel.urls {
                _ = url.startAccessingSecurityScopedResource()
            }
        }
    }
}

public struct FullDiskAccessSheetView: View {
    @ObservedObject var viewModel: CommanderViewModel
    @State private var isGranted: Bool = FullDiskAccessHelper.hasFullDiskAccess()
    private func dismiss() { CommanderDialog.close(viewModel) }


    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: isGranted ? "lock.open.fill" : "lock.shield.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(isGranted ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Grant Full Disk Access to All Files")
                        .font(.headline)
                    Text(
                        isGranted
                            ? "✅ Full Disk Access is active — macOS will not prompt per folder!"
                            : "To stop macOS from asking permission for each folder (Desktop, Downloads, Volumes), enable Full Disk Access once:"
                    )
                    .font(.subheadline)
                    .foregroundColor(isGranted ? .green : .secondary)
                }
            }

            Divider()

            GroupBox(label: Text("Method 1 (Recommended — Permanent macOS Full Disk Access):")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. Click below to open System Settings -> Full Disk Access.\n2. Toggle ON CZ.commander (or drag CZ.commander.app into the list).")
                    .font(.caption)

                    HStack(spacing: 10) {
                        Button("⚙️ Open System Settings (Full Disk Access)") {
                            FullDiskAccessHelper.openFullDiskAccessSettings()
                        }
                        .buttonStyle(SquareProminentButtonStyle())

                        Button("📁 Reveal CZ.commander.app in Finder") {
                            let appPath = FileManager.default.fileExists(atPath: "/Applications/CZ.commander.app")
                                ? "/Applications/CZ.commander.app"
                                : Bundle.main.bundlePath
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: appPath)])
                        }
                    }
                }
                .padding(8)
            }

            GroupBox(label: Text("Method 2 (Instant Root / Volume Unlock Dialog):")) {
                HStack {
                    Text("Select / (Root) once in the macOS Open dialog to unlock all subfolders:")
                        .font(.caption)
                    Spacer()
                    Button("🔓 Unlock Root (/) Now...") {
                        FullDiskAccessHelper.requestRootFolderAccessViaOpenPanel()
                        isGranted = FullDiskAccessHelper.hasFullDiskAccess()
                        viewModel.refreshVolumes()
                    }
                }
                .padding(8)
            }

            HStack {
                Button("Re-check Status") {
                    isGranted = FullDiskAccessHelper.hasFullDiskAccess()
                }
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 660)
    }
}
