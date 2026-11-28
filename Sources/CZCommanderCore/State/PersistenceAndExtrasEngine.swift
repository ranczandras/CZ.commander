import Foundation

// MARK: - 1. Persistence Manager (wincmd.ini equivalent for macOS)

public struct SavedTabDescriptor: Codable, Hashable, Sendable {
    public var customTitle: String?
    public var path: String
    /// Locked folder of a locked tab (nil for unlocked tabs / older config files).
    public var lockedBasePath: String?
    public var lockState: TabLockState
    public var viewMode: PanelViewMode
    public var sortColumn: PanelSortColumn
    public var sortAscending: Bool

    public init(
        customTitle: String? = nil,
        path: String,
        lockedBasePath: String? = nil,
        lockState: TabLockState = .unlocked,
        viewMode: PanelViewMode = .full,
        sortColumn: PanelSortColumn = .name,
        sortAscending: Bool = true
    ) {
        self.customTitle = customTitle
        self.path = path
        self.lockedBasePath = lockedBasePath
        self.lockState = lockState
        self.viewMode = viewMode
        self.sortColumn = sortColumn
        self.sortAscending = sortAscending
    }
}

public struct MultiRenamePreset: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var config: MultiRenameConfig

    public init(id: UUID = UUID(), name: String, config: MultiRenameConfig) {
        self.id = id
        self.name = name
        self.config = config
    }

    public static let builtInPresets: [MultiRenamePreset] = [
        MultiRenamePreset(
            name: "📅 Date + Counter ([YMD]_[C])",
            config: MultiRenameConfig(nameMask: "[YMD]_[C]", extensionMask: "[E]", counterStart: 1, counterStep: 1, counterDigits: 3)
        ),
        MultiRenamePreset(
            name: "🔤 Spaces -> Underscores + Lowercase",
            config: MultiRenameConfig(nameMask: "[N]", extensionMask: "[E]", searchFor: " ", replaceWith: "_", caseMode: .allLowercase)
        ),
        MultiRenamePreset(
            name: "📁 Parent Folder Prefix ([P]_[N])",
            config: MultiRenameConfig(nameMask: "[P]_[N]", extensionMask: "[E]")
        ),
        MultiRenamePreset(
            name: "🔢 Numbered Prefix ([C] - [N])",
            config: MultiRenameConfig(nameMask: "[C] - [N]", extensionMask: "[E]", counterStart: 1, counterStep: 1, counterDigits: 2)
        ),
        MultiRenamePreset(
            name: "✂️ Strip First 4 Characters ([N5-])",
            config: MultiRenameConfig(nameMask: "[N5-]", extensionMask: "[E]")
        )
    ]
}

public struct CommanderSavedConfiguration: Codable, Sendable {
    public var themeID: CommanderThemeID
    public var sizeDisplayFormat: FileSizeDisplayFormat
    public var fontSize: Double
    public var isHorizontalSplit: Bool
    public var showHiddenFiles: Bool
    public var showButtonBar: Bool
    public var showDriveBar: Bool
    public var showCommandLine: Bool
    public var showFunctionKeyBar: Bool
    public var leftTabs: [SavedTabDescriptor]
    public var leftActiveTabIndex: Int
    public var rightTabs: [SavedTabDescriptor]
    public var rightActiveTabIndex: Int
    public var hotlist: [DirectoryHotlistItem]
    public var remoteProfiles: [RemoteConnectionProfile]
    public var buttonBarItems: [ButtonBarItem]
    public var multiRenamePresets: [MultiRenamePreset]
    public var commandHistory: [String]
    /// "left" / "right": the panel that had the keyboard (optional, older files lack it).
    public var activeSide: String?

    public init(
        themeID: CommanderThemeID = .windowsDefault,
        sizeDisplayFormat: FileSizeDisplayFormat = .dynamicKMG,
        fontSize: Double = 12.5,
        isHorizontalSplit: Bool = false,
        showHiddenFiles: Bool = false,
        showButtonBar: Bool = true,
        showDriveBar: Bool = true,
        showCommandLine: Bool = true,
        showFunctionKeyBar: Bool = true,
        leftTabs: [SavedTabDescriptor] = [],
        leftActiveTabIndex: Int = 0,
        rightTabs: [SavedTabDescriptor] = [],
        rightActiveTabIndex: Int = 0,
        hotlist: [DirectoryHotlistItem] = [],
        remoteProfiles: [RemoteConnectionProfile] = [],
        buttonBarItems: [ButtonBarItem] = [],
        multiRenamePresets: [MultiRenamePreset] = MultiRenamePreset.builtInPresets,
        commandHistory: [String] = [],
        activeSide: String? = nil
    ) {
        self.themeID = themeID
        self.sizeDisplayFormat = sizeDisplayFormat
        self.fontSize = fontSize
        self.isHorizontalSplit = isHorizontalSplit
        self.showHiddenFiles = showHiddenFiles
        self.showButtonBar = showButtonBar
        self.showDriveBar = showDriveBar
        self.showCommandLine = showCommandLine
        self.showFunctionKeyBar = showFunctionKeyBar
        self.leftTabs = leftTabs
        self.leftActiveTabIndex = leftActiveTabIndex
        self.rightTabs = rightTabs
        self.rightActiveTabIndex = rightActiveTabIndex
        self.hotlist = hotlist
        self.remoteProfiles = remoteProfiles
        self.buttonBarItems = buttonBarItems
        self.multiRenamePresets = multiRenamePresets
        self.commandHistory = commandHistory
        self.activeSide = activeSide
    }
}

public enum PersistenceManager {
    /// `~/Library/Application Support/CZ.commander/config.json`
    public static var defaultConfigFilePath: String {
        // Test runs point this at a scratch file (CZ_CONFIG_PATH=/tmp/x.json).
        if let override = ProcessInfo.processInfo.environment["CZ_CONFIG_PATH"], !override.isEmpty {
            return override
        }
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("CZ.commander", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json").path
    }

    /// Older location used before the move to Application Support (read-only fallback).
    static var legacyConfigFilePath: String {
        (FileManager.default.homeDirectoryForCurrentUser.path as NSString).appendingPathComponent(".wincmd_mac.json")
    }

    public static func saveConfiguration(_ config: CommanderSavedConfiguration, toPath path: String? = nil) throws {
        let target = path ?? defaultConfigFilePath
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: URL(fileURLWithPath: target), options: .atomic)
    }

    public static func loadConfiguration(fromPath path: String? = nil) -> CommanderSavedConfiguration? {
        let target = path ?? defaultConfigFilePath
        let fallback = path == nil ? legacyConfigFilePath : nil
        guard let data = (try? Data(contentsOf: URL(fileURLWithPath: target)))
                ?? fallback.flatMap({ try? Data(contentsOf: URL(fileURLWithPath: $0)) }) else { return nil }
        return try? JSONDecoder().decode(CommanderSavedConfiguration.self, from: data)
    }
}

// MARK: - 2. File Properties & Hash Inspector (Alt+Enter / Cmd+I)

public struct DetailedFileProperties: Sendable {
    public let item: FileItem
    public let fileTypeMagicDescription: String
    public let recursiveFileCount: Int
    public let recursiveSubdirCount: Int
    public let totalRecursiveBytes: Int64
    public let crc32: String
    public let md5: String
    public let sha1: String
    public let sha256: String
    public let sha512: String
}

public enum FilePropertiesInspectorEngine {
    public static func inspectDetailedProperties(
        for item: FileItem,
        computeHashes: Bool = true
    ) -> DetailedFileProperties {
        let magic = (try? ArchiveEngine.runCommand(executable: "/usr/bin/file", arguments: ["-b", item.fullPath]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? (item.isDirectory ? "Directory" : "Regular File")

        var fileCount = item.isDirectory ? 0 : 1
        var dirCount = item.isDirectory ? 1 : 0
        var totalBytes = item.size

        if item.isDirectory, let enumerator = FileManager.default.enumerator(atPath: item.fullPath) {
            totalBytes = 0
            while let rel = enumerator.nextObject() as? String {
                let full = (item.fullPath as NSString).appendingPathComponent(rel)
                var st = stat()
                if lstat(full, &st) == 0 {
                    if (st.st_mode & S_IFMT) == S_IFDIR {
                        dirCount += 1
                    } else if (st.st_mode & S_IFMT) == S_IFREG {
                        fileCount += 1
                        totalBytes += Int64(st.st_size)
                    }
                }
            }
        }

        var crc = "—"
        var md5 = "—"
        var sha1 = "—"
        var sha256 = "—"
        var sha512 = "—"

        if computeHashes && !item.isDirectory && item.size <= 512 * 1024 * 1024 {
            crc = (try? ChecksumEngine.computeChecksum(ofFileAt: item.fullPath, kind: .crc32)) ?? "—"
            md5 = (try? ChecksumEngine.computeChecksum(ofFileAt: item.fullPath, kind: .md5)) ?? "—"
            sha1 = (try? ChecksumEngine.computeChecksum(ofFileAt: item.fullPath, kind: .sha1)) ?? "—"
            sha256 = (try? ChecksumEngine.computeChecksum(ofFileAt: item.fullPath, kind: .sha256)) ?? "—"
            sha512 = (try? ChecksumEngine.computeChecksum(ofFileAt: item.fullPath, kind: .sha512)) ?? "—"
        }

        return DetailedFileProperties(
            item: item,
            fileTypeMagicDescription: magic,
            recursiveFileCount: fileCount,
            recursiveSubdirCount: dirCount,
            totalRecursiveBytes: totalBytes,
            crc32: crc,
            md5: md5,
            sha1: sha1,
            sha256: sha256,
            sha512: sha512
        )
    }
}

// MARK: - 3. File List Catalog Exporter (TXT, CSV, Markdown, HTML)

public enum FileListExportFormat: String, CaseIterable, Codable, Sendable {
    case plainText = "txt"
    case csv = "csv"
    case markdown = "md"
    case html = "html"

    public var displayName: String {
        switch self {
        case .plainText: return "Plain Text Table (.txt)"
        case .csv: return "CSV Spreadsheet (.csv)"
        case .markdown: return "Markdown Table (.md)"
        case .html: return "HTML Report (.html)"
        }
    }
}

public enum FileListExporterEngine {
    public static func formatFileList(
        items: [FileItem],
        directoryPath: String,
        format: FileListExportFormat
    ) -> String {
        let valid = items.filter { !$0.isParentDirectoryEntry }
        switch format {
        case .plainText:
            var lines: [String] = [
                "Directory: \(directoryPath)",
                String(repeating: "=", count: 78),
                String(format: "%-36s %12s  %-16s  %-10s", "Name", "Size", "Modified", "Attr"),
                String(repeating: "-", count: 78)
            ]
            for item in valid {
                let sz = item.isDirectory ? "<DIR>" : "\(item.size)"
                let row = "\(item.name.padding(toLength: 36, withPad: " ", startingAt: 0)) \(sz.padding(toLength: 12, withPad: " ", startingAt: 0))  \(item.formattedModificationDate)  \(item.permissionsString)"
                lines.append(row)
            }
            return lines.joined(separator: "\n") + "\n"

        case .csv:
            var lines: [String] = ["\"Name\",\"Extension\",\"SizeBytes\",\"IsDirectory\",\"Modified\",\"Permissions\",\"FullPath\""]
            for item in valid {
                let escapedName = item.name.replacingOccurrences(of: "\"", with: "\"\"")
                let escapedPath = item.fullPath.replacingOccurrences(of: "\"", with: "\"\"")
                lines.append("\"\(escapedName)\",\"\(item.ext)\",\(item.effectiveSize),\(item.isDirectory),\"\(item.formattedModificationDate)\",\"\(item.permissionsString)\",\"\(escapedPath)\"")
            }
            return lines.joined(separator: "\n") + "\n"

        case .markdown:
            var lines: [String] = [
                "# File List — `\(directoryPath)`",
                "",
                "| Name | Ext | Size | Modified | Permissions |",
                "| :--- | :--- | ---: | :--- | :--- |"
            ]
            for item in valid {
                lines.append("| `\(item.name)` | `\(item.ext)` | \(item.formattedSize(format: .dynamicKMG)) | \(item.formattedModificationDate) | `\(item.permissionsString)` |")
            }
            return lines.joined(separator: "\n") + "\n"

        case .html:
            var rows = ""
            for item in valid {
                rows += "<tr><td>\(item.name)</td><td>\(item.ext)</td><td style='text-align:right'>\(item.formattedSize(format: .dynamicKMG))</td><td>\(item.formattedModificationDate)</td><td><code>\(item.permissionsString)</code></td></tr>\n"
            }
            return """
            <!DOCTYPE html>
            <html><head><meta charset="utf-8"><title>CZ.commander File List</title>
            <style>body{font-family:monospace;background:#16181d;color:#e6e9f0;padding:20px}table{border-collapse:collapse;width:100%}th,td{border:1px solid #303642;padding:6px 10px;text-align:left}th{background:#1f5692;color:#fff}</style>
            </head><body><h2>Directory: \(directoryPath)</h2>
            <table><thead><tr><th>Name</th><th>Ext</th><th>Size</th><th>Modified</th><th>Attr</th></tr></thead>
            <tbody>\(rows)</tbody></table></body></html>
            """
        }
    }
}
