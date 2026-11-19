import Foundation
import UniformTypeIdentifiers

public enum FileSizeDisplayFormat: String, CaseIterable, Codable, Sendable {
    case bytes = "bytes"
    case kilobytes = "kilobytes"
    case dynamicKMG = "dynamicKMG"
    case dynamicKMGT = "dynamicKMGT"
}

public enum FileCategory: String, Codable, Sendable {
    case parentDirectory
    case directory
    case symlink
    case executable
    case archive
    case image
    case audioVideo
    case document
    case sourceCode
    case hidden
    case regular
}

public enum FinderTagColor: Int, CaseIterable, Codable, Sendable {
    case none = 0
    case gray = 1
    case green = 2
    case purple = 3
    case blue = 4
    case yellow = 5
    case red = 6
    case orange = 7

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .gray: return "Gray"
        case .green: return "Green"
        case .purple: return "Purple"
        case .blue: return "Blue"
        case .yellow: return "Yellow"
        case .red: return "Red"
        case .orange: return "Orange"
        }
    }

}

public struct FileItem: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var name: String
    public var fullPath: String
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var symlinkTarget: String?
    public var isHidden: Bool
    public var isLocked: Bool
    public var isExecutable: Bool
    public var isParentDirectoryEntry: Bool
    public var size: Int64
    public var calculatedDirectorySize: Int64?
    public var isCalculatingSize: Bool = false
    public var modificationDate: Date
    public var creationDate: Date
    public var posixPermissions: UInt16
    public var ownerName: String
    public var groupName: String
    public var finderComment: String
    public var descriptionComment: String
    public var finderTagColor: FinderTagColor
    public var relativeDisplayPath: String?
    public var archiveContainerPath: String?
    public var archiveInternalPath: String?
    public var remoteConnectionID: UUID?

    public init(
        id: String? = nil,
        name: String,
        fullPath: String,
        isDirectory: Bool,
        isSymlink: Bool = false,
        symlinkTarget: String? = nil,
        isHidden: Bool = false,
        isLocked: Bool = false,
        isExecutable: Bool = false,
        isParentDirectoryEntry: Bool = false,
        size: Int64 = 0,
        calculatedDirectorySize: Int64? = nil,
        modificationDate: Date = Date(),
        creationDate: Date = Date(),
        posixPermissions: UInt16 = 0o644,
        ownerName: String = "",
        groupName: String = "",
        finderComment: String = "",
        descriptionComment: String = "",
        finderTagColor: FinderTagColor = .none,
        relativeDisplayPath: String? = nil,
        archiveContainerPath: String? = nil,
        archiveInternalPath: String? = nil,
        remoteConnectionID: UUID? = nil
    ) {
        self.id = id ?? fullPath
        self.name = name
        self.fullPath = fullPath
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.symlinkTarget = symlinkTarget
        self.isHidden = isHidden
        self.isLocked = isLocked
        self.isExecutable = isExecutable
        self.isParentDirectoryEntry = isParentDirectoryEntry
        self.size = size
        self.calculatedDirectorySize = calculatedDirectorySize
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.posixPermissions = posixPermissions
        self.ownerName = ownerName
        self.groupName = groupName
        self.finderComment = finderComment
        self.descriptionComment = descriptionComment
        self.finderTagColor = finderTagColor
        self.relativeDisplayPath = relativeDisplayPath
        self.archiveContainerPath = archiveContainerPath
        self.archiveInternalPath = archiveInternalPath
        self.remoteConnectionID = remoteConnectionID
    }

    public static func parentEntry(for parentPath: String) -> FileItem {
        FileItem(
            id: "parent::\(parentPath)",
            name: "..",
            fullPath: parentPath,
            isDirectory: true,
            isParentDirectoryEntry: true,
            size: 0,
            modificationDate: Date.distantPast,
            creationDate: Date.distantPast,
            posixPermissions: 0o755
        )
    }

    /// Stem (name without extension) as displayed in Total Commander's Name column
    public var stem: String {
        if isParentDirectoryEntry { return ".." }
        if isDirectory { return name }
        guard let dotIndex = name.lastIndex(of: "."), dotIndex != name.startIndex else {
            return name
        }
        return String(name[..<dotIndex])
    }

    /// Extension without leading dot as displayed in Total Commander's Ext column
    public var ext: String {
        if isParentDirectoryEntry || isDirectory { return "" }
        guard let dotIndex = name.lastIndex(of: "."), dotIndex != name.startIndex else {
            return ""
        }
        let nextIndex = name.index(after: dotIndex)
        return String(name[nextIndex...])
    }

    public var isArchive: Bool {
        if isDirectory { return false }
        let lower = name.lowercased()
        let archiveSuffixes = [
            ".zip", ".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tbz",
            ".tar.xz", ".txz", ".7z", ".iso", ".cpio", ".xar", ".jar", ".war", ".ipa"
        ]
        return archiveSuffixes.contains { lower.hasSuffix($0) }
    }

    public var effectiveSize: Int64 {
        if isDirectory {
            return calculatedDirectorySize ?? 0
        }
        return size
    }

    public var combinedComment: String {
        if !descriptionComment.isEmpty && !finderComment.isEmpty {
            return "\(descriptionComment) | \(finderComment)"
        }
        return !descriptionComment.isEmpty ? descriptionComment : finderComment
    }

    public var permissionsString: String {
        let typeChar: Character = isSymlink ? "l" : (isDirectory ? "d" : "-")
        let perms: [(UInt16, Character)] = [
            (0o400, "r"), (0o200, "w"), (0o100, "x"),
            (0o040, "r"), (0o020, "w"), (0o010, "x"),
            (0o004, "r"), (0o002, "w"), (0o001, "x")
        ]
        var result = String(typeChar)
        for (mask, ch) in perms {
            result.append((posixPermissions & mask) != 0 ? ch : "-")
        }
        if isLocked {
            result.append("L")
        }
        if isHidden {
            result.append("H")
        }
        return result
    }

    public var octalPermissionsString: String {
        String(format: "%03o", posixPermissions & 0o777)
    }

    public var category: FileCategory {
        if isParentDirectoryEntry { return .parentDirectory }
        if isDirectory { return .directory }
        if isSymlink { return .symlink }
        if isHidden { return .hidden }
        if isArchive { return .archive }
        if isExecutable { return .executable }

        let lowerExt = ext.lowercased()
        switch lowerExt {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "svg", "icns", "ico":
            return .image
        case "mp3", "wav", "flac", "aac", "m4a", "ogg", "mp4", "mov", "mkv", "avi", "webm", "m4v":
            return .audioVideo
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "md", "pages", "numbers", "key":
            return .document
        case "swift", "c", "cpp", "h", "hpp", "m", "mm", "py", "js", "ts", "tsx", "jsx", "rs", "go", "java", "kt", "rb", "sh", "zsh", "json", "yaml", "yml", "xml", "html", "css", "sql", "toml":
            return .sourceCode
        default:
            return .regular
        }
    }

    public func formattedSize(format: FileSizeDisplayFormat = .dynamicKMG) -> String {
        if isParentDirectoryEntry { return "<DIR>" }
        if isDirectory {
            if isCalculatingSize {
                if let partial = calculatedDirectorySize, partial > 0 {
                    return "…" + Self.formatByteCount(partial, format: format)
                }
                return "… ⏳"
            }
            if let calcSize = calculatedDirectorySize {
                return Self.formatByteCount(calcSize, format: format)
            }
            return isSymlink ? "<LNK>" : "<DIR>"
        }
        return Self.formatByteCount(size, format: format)
    }

    public static func formatByteCount(_ bytes: Int64, format: FileSizeDisplayFormat = .dynamicKMG) -> String {
        switch format {
        case .bytes:
            return formatWithThousandsSeparator(bytes)
        case .kilobytes:
            let kb = max(1, (bytes + 1023) / 1024)
            return "\(formatWithThousandsSeparator(kb)) k"
        case .dynamicKMG:
            if bytes < 1_000_000 {
                return formatWithThousandsSeparator(bytes)
            } else if bytes < 1_000_000_000 {
                return String(format: "%.1f M", Double(bytes) / 1_048_576.0)
            } else {
                return String(format: "%.2f G", Double(bytes) / 1_073_741_824.0)
            }
        case .dynamicKMGT:
            if bytes < 1024 {
                return "\(bytes) B"
            } else if bytes < 1_048_576 {
                return String(format: "%.1f k", Double(bytes) / 1024.0)
            } else if bytes < 1_073_741_824 {
                return String(format: "%.1f M", Double(bytes) / 1_048_576.0)
            } else if bytes < 1_099_511_627_776 {
                return String(format: "%.2f G", Double(bytes) / 1_073_741_824.0)
            } else {
                return String(format: "%.2f T", Double(bytes) / 1_099_511_627_776.0)
            }
        }
    }

    @inline(__always)
    public static func formatWithThousandsSeparator(_ value: Int64) -> String {
        if value < 1000 && value > -1000 { return String(value) }
        var n = value < 0 ? -value : value
        var groups: [String] = []
        while n >= 1000 {
            let rem = n % 1000
            if rem < 10 {
                groups.append("00\(rem)")
            } else if rem < 100 {
                groups.append("0\(rem)")
            } else {
                groups.append(String(rem))
            }
            n /= 1000
        }
        groups.append(String(n))
        let joined = groups.reversed().joined(separator: " ")
        return value < 0 ? "-\(joined)" : joined
    }

    private static let tcDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df
    }()

    public var formattedModificationDate: String {
        if isParentDirectoryEntry { return "" }
        return Self.tcDateFormatter.string(from: modificationDate)
    }
}
