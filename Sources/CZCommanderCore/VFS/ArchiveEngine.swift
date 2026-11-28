import Foundation

public enum ArchiveFormat: String, CaseIterable, Codable, Sendable {
    case zip = "zip"
    case tar = "tar"
    case tarGz = "tar.gz"
    case tarBz2 = "tar.bz2"
    case tarXz = "tar.xz"

    public var fileExtension: String { rawValue }

    public static func detect(fromPath path: String) -> ArchiveFormat {
        let lower = path.lowercased()
        if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") { return .tarGz }
        if lower.hasSuffix(".tar.bz2") || lower.hasSuffix(".tbz2") || lower.hasSuffix(".tbz") { return .tarBz2 }
        if lower.hasSuffix(".tar.xz") || lower.hasSuffix(".txz") { return .tarXz }
        if lower.hasSuffix(".tar") { return .tar }
        return .zip
    }
}

public struct PackOptions: Codable, Sendable {
    public var format: ArchiveFormat
    public var compressionLevel: Int // 0..9
    public var includeParentPaths: Bool
    public var recurseSubdirectories: Bool
    public var moveToArchive: Bool
    public var separateArchivePerItem: Bool
    public var password: String?

    public init(
        format: ArchiveFormat = .zip,
        compressionLevel: Int = 6,
        includeParentPaths: Bool = false,
        recurseSubdirectories: Bool = true,
        moveToArchive: Bool = false,
        separateArchivePerItem: Bool = false,
        password: String? = nil
    ) {
        self.format = format
        self.compressionLevel = min(9, max(0, compressionLevel))
        self.includeParentPaths = includeParentPaths
        self.recurseSubdirectories = recurseSubdirectories
        self.moveToArchive = moveToArchive
        self.separateArchivePerItem = separateArchivePerItem
        self.password = password
    }
}

public struct ArchiveTestResult: Sendable {
    public let archivePath: String
    public let isValid: Bool
    public let testedEntriesCount: Int
    public let message: String
}

public struct RawArchiveEntry: Sendable {
    public let internalPath: String
    public let isDirectory: Bool
    public let size: Int64
    public let modificationDate: Date
    public let permissions: UInt16
}

public enum ArchiveEngine {
    // MARK: - List Archive Entries as Virtual Directory (Enter on Archive)

    public static func listArchiveDirectory(
        archivePath: String,
        internalDirectory: String = ""
    ) throws -> [FileItem] {
        let rawEntries = try readAllArchiveEntries(archivePath: archivePath)
        let normalizedPrefix: String = {
            let trimmed = internalDirectory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return trimmed.isEmpty ? "" : trimmed + "/"
        }()

        // Parent entry (`..`): if at root of archive, `..` exits the archive back to its parent folder on disk!
        let parentTargetPath: String
        if normalizedPrefix.isEmpty {
            parentTargetPath = (archivePath as NSString).deletingLastPathComponent
        } else {
            let withoutTrailing = String(normalizedPrefix.dropLast())
            if let slashIdx = withoutTrailing.lastIndex(of: "/") {
                let parentInternal = String(withoutTrailing[..<slashIdx])
                parentTargetPath = "\(archivePath)#/\(parentInternal)"
            } else {
                parentTargetPath = "\(archivePath)#/"
            }
        }

        var items: [FileItem] = [
            FileItem(
                id: "archive-parent::\(archivePath)::\(normalizedPrefix)",
                name: "..",
                fullPath: parentTargetPath,
                isDirectory: true,
                isParentDirectoryEntry: true,
                archiveContainerPath: archivePath,
                archiveInternalPath: normalizedPrefix.isEmpty ? nil : normalizedPrefix
            )
        ]

        var seenNames: Set<String> = []
        var synthesizedDirs: [String: (Date, UInt16)] = [:]
        var directFiles: [FileItem] = []

        for entry in rawEntries {
            let cleanPath = entry.internalPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if cleanPath.isEmpty { continue }

            guard cleanPath.hasPrefix(normalizedPrefix) else { continue }
            let remainder = String(cleanPath.dropFirst(normalizedPrefix.count))
            if remainder.isEmpty { continue }

            if let slashIdx = remainder.firstIndex(of: "/") {
                // Child is inside a subdirectory of current level
                let subdirName = String(remainder[..<slashIdx])
                if !subdirName.isEmpty && synthesizedDirs[subdirName] == nil {
                    synthesizedDirs[subdirName] = (entry.modificationDate, 0o755)
                }
            } else {
                // Direct child at current level
                if entry.isDirectory {
                    synthesizedDirs[remainder] = (entry.modificationDate, entry.permissions)
                } else if !seenNames.contains(remainder) {
                    seenNames.insert(remainder)
                    directFiles.append(
                        FileItem(
                            id: "archive-item::\(archivePath)::\(cleanPath)",
                            name: remainder,
                            fullPath: "\(archivePath)#/\(cleanPath)",
                            isDirectory: false,
                            size: entry.size,
                            modificationDate: entry.modificationDate,
                            creationDate: entry.modificationDate,
                            posixPermissions: entry.permissions,
                            descriptionComment: "Archive entry",
                            archiveContainerPath: archivePath,
                            archiveInternalPath: cleanPath
                        )
                    )
                }
            }
        }

        for (dirName, meta) in synthesizedDirs.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }) {
            let internalSubpath = normalizedPrefix + dirName
            items.append(
                FileItem(
                    id: "archive-dir::\(archivePath)::\(internalSubpath)",
                    name: dirName,
                    fullPath: "\(archivePath)#/\(internalSubpath)",
                    isDirectory: true,
                    size: 0,
                    modificationDate: meta.0,
                    creationDate: meta.0,
                    posixPermissions: meta.1,
                    archiveContainerPath: archivePath,
                    archiveInternalPath: internalSubpath
                )
            )
        }

        items.append(contentsOf: directFiles)
        return items
    }

    public static func readAllArchiveEntries(archivePath: String) throws -> [RawArchiveEntry] {
        let output = try runCommand(executable: "/usr/bin/tar", arguments: ["-tvf", archivePath])
        var entries: [RawArchiveEntry] = []

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            // Typical bsdtar -tvf line on macOS:
            // drwxr-xr-x  0 user   group       0 Nov 14 14:30 folder/
            // -rw-r--r--  0 user   group    1234 Nov 14 14:30 folder/file.txt
            let tokens = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard tokens.count >= 9 else { continue }
            let permToken = String(tokens[0])
            let isDir = permToken.hasPrefix("d") || tokens[8].hasSuffix("/")
            let size = Int64(tokens[4]) ?? 0
            let rawPath = String(tokens[8])
            let pathPart = rawPath.components(separatedBy: " -> ").first ?? rawPath
            let perms = parsePermString(permToken)

            entries.append(
                RawArchiveEntry(
                    internalPath: pathPart,
                    isDirectory: isDir,
                    size: size,
                    modificationDate: Date(),
                    permissions: perms
                )
            )
        }
        return entries
    }

    private static func parsePermString(_ str: String) -> UInt16 {
        let chars = Array(str)
        guard chars.count >= 10 else { return 0o644 }
        var mode: UInt16 = 0
        if chars[1] == "r" { mode |= 0o400 }
        if chars[2] == "w" { mode |= 0o200 }
        if chars[3] == "x" || chars[3] == "s" { mode |= 0o100 }
        if chars[4] == "r" { mode |= 0o040 }
        if chars[5] == "w" { mode |= 0o020 }
        if chars[6] == "x" || chars[6] == "s" { mode |= 0o010 }
        if chars[7] == "r" { mode |= 0o004 }
        if chars[8] == "w" { mode |= 0o002 }
        if chars[9] == "x" || chars[9] == "t" { mode |= 0o001 }
        return mode
    }

    // MARK: - Pack Files (Alt+F5)

    @discardableResult
    public static func packFiles(
        sourcePaths: [String],
        toArchivePath archivePath: String,
        options: PackOptions = PackOptions()
    ) throws -> [String] {
        guard !sourcePaths.isEmpty else { return [] }
        let fm = FileManager.default

        if options.separateArchivePerItem {
            let targetDir = (archivePath as NSString).deletingLastPathComponent
            var createdArchives: [String] = []
            for src in sourcePaths {
                let baseName = ((src as NSString).lastPathComponent as NSString).deletingPathExtension
                let singleArchive = (targetDir as NSString).appendingPathComponent("\(baseName).\(options.format.fileExtension)")
                var singleOpt = options
                singleOpt.separateArchivePerItem = false
                let res = try packFiles(sourcePaths: [src], toArchivePath: singleArchive, options: singleOpt)
                createdArchives.append(contentsOf: res)
            }
            return createdArchives
        }

        let destDir = (archivePath as NSString).deletingLastPathComponent
        if !destDir.isEmpty && !fm.fileExists(atPath: destDir) {
            try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        }

        // Remove existing archive if we are creating fresh
        if fm.fileExists(atPath: archivePath) {
            try? fm.removeItem(atPath: archivePath)
        }

        let commonBaseDir = (sourcePaths[0] as NSString).deletingLastPathComponent
        let relativeNames = sourcePaths.map { path -> String in
            if path.hasPrefix(commonBaseDir + "/") {
                return String(path.dropFirst(commonBaseDir.count + 1))
            }
            return (path as NSString).lastPathComponent
        }

        switch options.format {
        case .zip:
            var args: [String] = ["-\(options.compressionLevel)"]
            if options.recurseSubdirectories {
                args.append("-r")
            }
            if !options.includeParentPaths {
                // Run from commonBaseDir so paths are relative to commonBaseDir
                args.append(archivePath)
                args.append(contentsOf: relativeNames)
                _ = try runCommand(executable: "/usr/bin/zip", arguments: args, currentDirectory: commonBaseDir)
            } else {
                args.append(archivePath)
                args.append(contentsOf: sourcePaths)
                _ = try runCommand(executable: "/usr/bin/zip", arguments: args)
            }

        case .tar:
            var args = ["-cf", archivePath, "-C", commonBaseDir]
            args.append(contentsOf: relativeNames)
            _ = try runCommand(executable: "/usr/bin/tar", arguments: args)

        case .tarGz:
            var args = ["-czf", archivePath, "-C", commonBaseDir]
            args.append(contentsOf: relativeNames)
            _ = try runCommand(executable: "/usr/bin/tar", arguments: args)

        case .tarBz2:
            var args = ["-cjf", archivePath, "-C", commonBaseDir]
            args.append(contentsOf: relativeNames)
            _ = try runCommand(executable: "/usr/bin/tar", arguments: args)

        case .tarXz:
            var args = ["-cJf", archivePath, "-C", commonBaseDir]
            args.append(contentsOf: relativeNames)
            _ = try runCommand(executable: "/usr/bin/tar", arguments: args)
        }

        if options.moveToArchive {
            try FileSystemEngine.deleteItems(atPaths: sourcePaths, moveToTrash: false)
        }

        return [archivePath]
    }

    // MARK: - Add Files to Existing Archive (F5 into open Archive)

    public static func addFilesToArchive(
        sourcePaths: [String],
        archivePath: String
    ) throws {
        guard !sourcePaths.isEmpty else { return }
        let format = ArchiveFormat.detect(fromPath: archivePath)
        let commonBaseDir = (sourcePaths[0] as NSString).deletingLastPathComponent
        let relativeNames = sourcePaths.map { (path: String) -> String in
            if path.hasPrefix(commonBaseDir + "/") {
                return String(path.dropFirst(commonBaseDir.count + 1))
            }
            return (path as NSString).lastPathComponent
        }

        if format == .zip {
            var args = ["-r", "-u", archivePath]
            args.append(contentsOf: relativeNames)
            _ = try runCommand(executable: "/usr/bin/zip", arguments: args, currentDirectory: commonBaseDir)
        } else if format == .tar {
            var args = ["-rf", archivePath, "-C", commonBaseDir]
            args.append(contentsOf: relativeNames)
            _ = try runCommand(executable: "/usr/bin/tar", arguments: args)
        } else {
            // For compressed tar archives (.tar.gz / .tar.bz2 / .tar.xz), extract to temp, add, and repack
            let tempDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("tc_repack_\(UUID().uuidString)")
            try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tempDir) }
            try unpackArchive(archivePath: archivePath, toDirectory: tempDir)
            _ = try FileSystemEngine.copyOrMoveItems(sources: sourcePaths, toDestinationDirectory: tempDir, isMove: false)
            let topItems = try FileManager.default.contentsOfDirectory(atPath: tempDir).map {
                (tempDir as NSString).appendingPathComponent($0)
            }
            _ = try packFiles(sourcePaths: topItems, toArchivePath: archivePath, options: PackOptions(format: format))
        }
    }

    // MARK: - Unpack Archive or Specific Entries (Alt+F9 / F5 / F3 inside Archive)

    /// Unpacks an archive. Whole archives (no `specificEntries`) follow the "smart folder" rule:
    /// when the top level holds only folders they are unpacked as they are; when it holds
    /// files too, everything goes into a new folder named after the archive ("photos.zip" ->
    /// "photos/"). `unpackEachToSeparateSubdir` always uses that folder.
    /// Returns the folder the content went into.
    @discardableResult
    public static func unpackArchive(
        archivePath: String,
        toDirectory destinationDirectory: String,
        specificEntries: [String]? = nil,
        unpackEachToSeparateSubdir: Bool = false
    ) throws -> String {
        let fm = FileManager.default
        let wholeArchive = specificEntries?.isEmpty ?? true
        var wrap = unpackEachToSeparateSubdir
        if !wrap && wholeArchive {
            let names = (try? listEntryNames(archivePath: archivePath)) ?? []
            wrap = needsWrapperFolder(entryNames: names)
        }
        let finalDestDir = wrap
            ? (destinationDirectory as NSString).appendingPathComponent(archiveStem(archivePath))
            : destinationDirectory

        if !fm.fileExists(atPath: finalDestDir) {
            try fm.createDirectory(atPath: finalDestDir, withIntermediateDirectories: true)
        }

        // Finder zips carry resource-fork copies in __MACOSX and .DS_Store files: never unpack them.
        var args = ["-xf", archivePath, "-C", finalDestDir, "--exclude", "__MACOSX", "--exclude", ".DS_Store"]
        if let entries = specificEntries, !entries.isEmpty {
            args.append(contentsOf: entries)
        }
        _ = try runCommand(executable: "/usr/bin/tar", arguments: args)
        return finalDestDir
    }

    /// Entry paths as stored in the archive (folders end with "/").
    public static func listEntryNames(archivePath: String) throws -> [String] {
        let output = try runCommand(executable: "/usr/bin/tar", arguments: ["-tf", archivePath])
        return output.components(separatedBy: .newlines).filter { !$0.isEmpty }
    }

    /// True when the archive's top level holds anything besides folders (a file, a link).
    /// `__MACOSX`, `.DS_Store` and "./" prefixes are ignored. An empty archive needs no folder.
    public static func needsWrapperFolder(entryNames: [String]) -> Bool {
        for raw in entryNames {
            var path = raw
            while path.hasPrefix("./") { path.removeFirst(2) }
            while path.hasPrefix("/") { path.removeFirst() }
            if path.isEmpty || path == "." { continue }
            let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            guard let first = parts.first else { continue }
            if first == "__MACOSX" || first == ".DS_Store" { continue }
            // "name" with nothing after it and no trailing slash is a top-level file.
            if parts.count == 1 && !path.hasSuffix("/") { return true }
        }
        return false
    }

    /// "photos.zip" -> "photos", "backup.tar.gz" -> "backup", "x.tgz" -> "x".
    public static func archiveStem(_ archivePath: String) -> String {
        let name = (archivePath as NSString).lastPathComponent
        let lower = name.lowercased()
        for ext in [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lz", ".tar.z"] where lower.hasSuffix(ext) {
            return String(name.dropLast(ext.count))
        }
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? name : stem
    }

    /// Extracts a single archive entry to a temporary file for F3 Lister or F4 Editor viewing
    public static func extractEntryToTemporaryFile(
        archivePath: String,
        internalPath: String
    ) throws -> String {
        let tempRoot = (NSTemporaryDirectory() as NSString).appendingPathComponent("tc_preview_\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: tempRoot, withIntermediateDirectories: true)
        try unpackArchive(archivePath: archivePath, toDirectory: tempRoot, specificEntries: [internalPath])
        let cleanRel = internalPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return (tempRoot as NSString).appendingPathComponent(cleanRel)
    }

    // MARK: - Delete Entries Inside Archive (F8 inside Archive)

    public static func deleteEntriesFromArchive(
        archivePath: String,
        internalPaths: [String]
    ) throws {
        guard !internalPaths.isEmpty else { return }
        let format = ArchiveFormat.detect(fromPath: archivePath)
        if format == .zip {
            var args = ["-d", archivePath]
            args.append(contentsOf: internalPaths)
            _ = try runCommand(executable: "/usr/bin/zip", arguments: args)
        } else {
            throw NSError(
                domain: "CZCommander.Archive",
                code: 405,
                userInfo: [NSLocalizedDescriptionKey: "In-place entry deletion is supported for ZIP archives."]
            )
        }
    }

    // MARK: - Test Archive Integrity (Alt+Shift+F9)

    public static func testArchive(atPath archivePath: String) -> ArchiveTestResult {
        do {
            let entries = try readAllArchiveEntries(archivePath: archivePath)
            if archivePath.lowercased().hasSuffix(".zip") {
                _ = try runCommand(executable: "/usr/bin/unzip", arguments: ["-t", archivePath])
            } else {
                _ = try runCommand(executable: "/usr/bin/tar", arguments: ["-tf", archivePath])
            }
            return ArchiveTestResult(
                archivePath: archivePath,
                isValid: true,
                testedEntriesCount: entries.count,
                message: "OK (\(entries.count) entries verified)"
            )
        } catch {
            return ArchiveTestResult(
                archivePath: archivePath,
                isValid: false,
                testedEntriesCount: 0,
                message: error.localizedDescription
            )
        }
    }

    // MARK: - Subprocess Runner

    public static func runCommand(
        executable: String,
        arguments: [String],
        currentDirectory: String? = nil
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let dir = currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let outStr = String(data: outData, encoding: .utf8) ?? ""
        let errStr = String(data: errData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            throw NSError(
                domain: "CZCommander.Archive",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: errStr.isEmpty ? outStr : errStr]
            )
        }
        return outStr
    }
}
