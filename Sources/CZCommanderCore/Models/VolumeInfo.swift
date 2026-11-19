import Foundation

public struct VolumeInfo: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let path: String
    public let fileSystemType: String
    public let totalBytes: Int64
    public let freeBytes: Int64
    public let isRemovable: Bool
    public let isInternal: Bool
    public let isQuickShortcut: Bool
    public let sfSymbolName: String

    public init(
        id: String? = nil,
        name: String,
        path: String,
        fileSystemType: String = "APFS",
        totalBytes: Int64 = 0,
        freeBytes: Int64 = 0,
        isRemovable: Bool = false,
        isInternal: Bool = true,
        isQuickShortcut: Bool = false,
        sfSymbolName: String = "internaldrive"
    ) {
        self.id = id ?? path
        self.name = name
        self.path = path
        self.fileSystemType = fileSystemType
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.isRemovable = isRemovable
        self.isInternal = isInternal
        self.isQuickShortcut = isQuickShortcut
        self.sfSymbolName = sfSymbolName
    }

    public var usedBytes: Int64 {
        max(0, totalBytes - freeBytes)
    }

    public var freeRatio: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(freeBytes) / Double(totalBytes)
    }

    /// Volume header text: `[Macintosh HD] (APFS) 51.52 GB free of 460.43 GB`
    public func tcHeaderDescription() -> String {
        "[\(name)] (\(fileSystemType)) \(FileItem.formatByteCount(freeBytes)) free of \(FileItem.formatByteCount(totalBytes))"
    }
}

public enum VolumeScanner {
    public static func mountedVolumes() -> [VolumeInfo] {
        var results: [VolumeInfo] = []
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsRemovableKey,
            .volumeIsInternalKey,
            .volumeLocalizedFormatDescriptionKey
        ]

        if let urls = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) {
            for url in urls {
                let path = url.path
                let res = try? url.resourceValues(forKeys: Set(keys))
                let volName = res?.volumeName ?? url.lastPathComponent
                let total = Int64(res?.volumeTotalCapacity ?? 0)
                let availImportant = res?.volumeAvailableCapacityForImportantUsage ?? 0
                let availStd = Int64(res?.volumeAvailableCapacity ?? 0)
                let free = availImportant > 0 ? availImportant : availStd
                let removable = res?.volumeIsRemovable ?? false
                let isInternal = res?.volumeIsInternal ?? (path == "/")
                let fsDesc = res?.volumeLocalizedFormatDescription ?? "APFS"
                let icon = removable ? "externaldrive.fill" : (path == "/" ? "internaldrive.fill" : "externaldrive")

                results.append(
                    VolumeInfo(
                        id: "vol:\(path)",
                        name: volName.isEmpty ? "Macintosh HD" : volName,
                        path: path,
                        fileSystemType: fsDesc,
                        totalBytes: total,
                        freeBytes: free,
                        isRemovable: removable,
                        isInternal: isInternal,
                        isQuickShortcut: false,
                        sfSymbolName: icon
                    )
                )
            }
        }

        // Also scan /Volumes directly in case external drives weren't returned by mountedVolumeURLs
        if let volEntries = try? fm.contentsOfDirectory(atPath: "/Volumes") {
            for entry in volEntries where !entry.hasPrefix(".") {
                let fullPath = "/Volumes/\(entry)"
                // "/Volumes/Macintosh HD" is a symlink to "/": skip entries that resolve to an already listed volume
                let resolved = (fullPath as NSString).resolvingSymlinksInPath
                if !results.contains(where: { $0.path == fullPath || $0.path == resolved }) {
                    if let info = volumeInfo(forPath: fullPath, customName: entry) {
                        results.append(info)
                    }
                }
            }
        }

        return results
    }

    public static func quickShortcuts() -> [VolumeInfo] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates: [(String, String, String)] = [
            ("~", home, "house.fill"),
            ("Desktop", (home as NSString).appendingPathComponent("Desktop"), "menubar.dock.rectangle"),
            ("Downloads", (home as NSString).appendingPathComponent("Downloads"), "arrow.down.circle.fill"),
            ("Documents", (home as NSString).appendingPathComponent("Documents"), "doc.fill"),
            ("Applications", "/Applications", "app.badge.fill"),
            ("Root /", "/", "externaldrive.connected.to.line.below"),
            ("Trash", (home as NSString).appendingPathComponent(".Trash"), "trash.fill")
        ]
        return candidates.map { (label, path, symbol) in
            VolumeInfo(
                id: "short:\(label):\(path)",
                name: label,
                path: path,
                fileSystemType: "APFS",
                totalBytes: 0,
                freeBytes: 0,
                isRemovable: false,
                isInternal: true,
                isQuickShortcut: true,
                sfSymbolName: symbol.trimmingCharacters(in: .whitespaces)
            )
        }
    }

    public static func volumeInfo(forPath path: String, customName: String? = nil) -> VolumeInfo? {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsRemovableKey,
            .volumeIsInternalKey,
            .volumeLocalizedFormatDescriptionKey
        ]
        let res = try? url.resourceValues(forKeys: keys)
        let attrs = try? fm.attributesOfFileSystem(forPath: path)
        let total = Int64(res?.volumeTotalCapacity ?? (attrs?[.systemSize] as? NSNumber)?.intValue ?? 0)
        let availImportant = res?.volumeAvailableCapacityForImportantUsage ?? 0
        let availStd = Int64(res?.volumeAvailableCapacity ?? (attrs?[.systemFreeSize] as? NSNumber)?.intValue ?? 0)
        let free = availImportant > 0 ? availImportant : availStd
        let name = customName ?? res?.volumeName ?? url.lastPathComponent
        let fsDesc = res?.volumeLocalizedFormatDescription ?? "APFS"
        let removable = res?.volumeIsRemovable ?? path.hasPrefix("/Volumes/")
        let isInternal = res?.volumeIsInternal ?? !path.hasPrefix("/Volumes/")

        return VolumeInfo(
            id: "path:\(path)",
            name: name.isEmpty ? "Macintosh HD" : name,
            path: path,
            fileSystemType: fsDesc,
            totalBytes: total,
            freeBytes: free,
            isRemovable: removable,
            isInternal: isInternal,
            isQuickShortcut: false,
            sfSymbolName: removable ? "externaldrive.fill" : "internaldrive.fill"
        )
    }
}
