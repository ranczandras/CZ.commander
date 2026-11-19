import Foundation

public enum SizeComparator: String, CaseIterable, Codable, Sendable {
    case any = "any"
    case greaterThan = ">"
    case lessThan = "<"
    case equalTo = "="
}

public enum SizeUnit: Int64, CaseIterable, Codable, Sendable {
    case bytes = 1
    case kilobytes = 1024
    case megabytes = 1_048_576
    case gigabytes = 1_073_741_824

    public var label: String {
        switch self {
        case .bytes: return "Bytes"
        case .kilobytes: return "KB"
        case .megabytes: return "MB"
        case .gigabytes: return "GB"
        }
    }
}

public enum AgeUnit: String, CaseIterable, Codable, Sendable {
    case minutes = "minutes"
    case hours = "hours"
    case days = "days"
    case weeks = "weeks"
    case months = "months"
    case years = "years"

    public var secondsMultiplier: TimeInterval {
        switch self {
        case .minutes: return 60
        case .hours: return 3600
        case .days: return 86_400
        case .weeks: return 604_800
        case .months: return 2_592_000
        case .years: return 31_536_000
        }
    }
}

public struct FindFilesQuery: Codable, Sendable {
    public var searchForMask: String
    public var searchInPaths: [String]
    public var useRegexForName: Bool
    public var maxDepth: Int? // nil = unlimited, 0 = current dir only, 1 = 1 level...
    public var searchInsideArchives: Bool
    public var includeHidden: Bool

    // Text search
    public var findText: String
    public var textCaseSensitive: Bool
    public var textWholeWordsOnly: Bool
    public var textUseRegex: Bool
    public var textHexMode: Bool
    public var invertTextMatch: Bool

    // Advanced filters
    public var dateBetweenEnabled: Bool
    public var dateFrom: Date
    public var dateTo: Date
    public var notOlderThanEnabled: Bool
    public var notOlderThanValue: Int
    public var notOlderThanUnit: AgeUnit

    public var sizeComparator: SizeComparator
    public var sizeValue: Int64
    public var sizeUnit: SizeUnit

    public var onlyDirectories: Bool
    public var onlyFiles: Bool
    public var onlyExecutables: Bool

    // Duplicate finder
    public var findDuplicates: Bool
    public var duplicatesSameName: Bool
    public var duplicatesSameSize: Bool
    public var duplicatesSameContent: Bool

    public init(
        searchForMask: String = "*",
        searchInPaths: [String] = [],
        useRegexForName: Bool = false,
        maxDepth: Int? = nil,
        searchInsideArchives: Bool = false,
        includeHidden: Bool = true,
        findText: String = "",
        textCaseSensitive: Bool = false,
        textWholeWordsOnly: Bool = false,
        textUseRegex: Bool = false,
        textHexMode: Bool = false,
        invertTextMatch: Bool = false,
        dateBetweenEnabled: Bool = false,
        dateFrom: Date = Date.distantPast,
        dateTo: Date = Date.distantFuture,
        notOlderThanEnabled: Bool = false,
        notOlderThanValue: Int = 7,
        notOlderThanUnit: AgeUnit = .days,
        sizeComparator: SizeComparator = .any,
        sizeValue: Int64 = 0,
        sizeUnit: SizeUnit = .kilobytes,
        onlyDirectories: Bool = false,
        onlyFiles: Bool = false,
        onlyExecutables: Bool = false,
        findDuplicates: Bool = false,
        duplicatesSameName: Bool = true,
        duplicatesSameSize: Bool = true,
        duplicatesSameContent: Bool = false
    ) {
        self.searchForMask = searchForMask
        self.searchInPaths = searchInPaths
        self.useRegexForName = useRegexForName
        self.maxDepth = maxDepth
        self.searchInsideArchives = searchInsideArchives
        self.includeHidden = includeHidden
        self.findText = findText
        self.textCaseSensitive = textCaseSensitive
        self.textWholeWordsOnly = textWholeWordsOnly
        self.textUseRegex = textUseRegex
        self.textHexMode = textHexMode
        self.invertTextMatch = invertTextMatch
        self.dateBetweenEnabled = dateBetweenEnabled
        self.dateFrom = dateFrom
        self.dateTo = dateTo
        self.notOlderThanEnabled = notOlderThanEnabled
        self.notOlderThanValue = notOlderThanValue
        self.notOlderThanUnit = notOlderThanUnit
        self.sizeComparator = sizeComparator
        self.sizeValue = sizeValue
        self.sizeUnit = sizeUnit
        self.onlyDirectories = onlyDirectories
        self.onlyFiles = onlyFiles
        self.onlyExecutables = onlyExecutables
        self.findDuplicates = findDuplicates
        self.duplicatesSameName = duplicatesSameName
        self.duplicatesSameSize = duplicatesSameSize
        self.duplicatesSameContent = duplicatesSameContent
    }
}

public struct FindFilesResult: Sendable {
    public let matchedItems: [FileItem]
    public let duplicateGroups: [[FileItem]]
    public let scannedFilesCount: Int
    public let scannedDirectoriesCount: Int
}

public enum FindFilesEngine {
    public static func search(query: FindFilesQuery) -> FindFilesResult {
        let fm = FileManager.default
        var candidateItems: [FileItem] = []
        var scannedFiles = 0
        var scannedDirs = 0

        let matcher = WildcardMaskMatcher(expression: query.searchForMask, isRegex: query.useRegexForName)
        let now = Date()

        for rawRoot in query.searchInPaths {
            let root = (rawRoot as NSString).standardizingPath
            guard fm.fileExists(atPath: root) else { continue }

            let rootItems = collectCandidates(
                atRoot: root,
                maxDepth: query.maxDepth,
                includeHidden: query.includeHidden
            )

            for item in rootItems {
                if item.isDirectory {
                    scannedDirs += 1
                } else {
                    scannedFiles += 1
                }

                if evaluateCandidate(item, query: query, matcher: matcher, now: now) {
                    candidateItems.append(item)
                }

                // Also inspect inside archives if requested
                if query.searchInsideArchives && item.isArchive {
                    if let archiveEntries = try? ArchiveEngine.readAllArchiveEntries(archivePath: item.fullPath) {
                        for entry in archiveEntries where !entry.isDirectory {
                            let entryName = (entry.internalPath as NSString).lastPathComponent
                            let archiveFileItem = FileItem(
                                id: "arch-find::\(item.fullPath)::\(entry.internalPath)",
                                name: entryName,
                                fullPath: "\(item.fullPath)#/\(entry.internalPath)",
                                isDirectory: false,
                                size: entry.size,
                                modificationDate: entry.modificationDate,
                                creationDate: entry.modificationDate,
                                posixPermissions: entry.permissions,
                                descriptionComment: "Inside \((item.fullPath as NSString).lastPathComponent)",
                                relativeDisplayPath: "\((item.fullPath as NSString).lastPathComponent)#/\(entry.internalPath)",
                                archiveContainerPath: item.fullPath,
                                archiveInternalPath: entry.internalPath
                            )
                            if matcher.matches(entryName) {
                                candidateItems.append(archiveFileItem)
                            }
                        }
                    }
                }
            }
        }

        if query.findDuplicates {
            let groups = groupDuplicates(
                items: candidateItems.filter { !$0.isDirectory && $0.archiveContainerPath == nil },
                sameName: query.duplicatesSameName,
                sameSize: query.duplicatesSameSize,
                sameContent: query.duplicatesSameContent
            )
            let flattened = groups.flatMap { $0 }
            return FindFilesResult(
                matchedItems: flattened,
                duplicateGroups: groups,
                scannedFilesCount: scannedFiles,
                scannedDirectoriesCount: scannedDirs
            )
        }

        return FindFilesResult(
            matchedItems: candidateItems,
            duplicateGroups: [],
            scannedFilesCount: scannedFiles,
            scannedDirectoriesCount: scannedDirs
        )
    }

    private static func collectCandidates(
        atRoot rootPath: String,
        maxDepth: Int?,
        includeHidden: Bool
    ) -> [FileItem] {
        let fm = FileManager.default
        var results: [FileItem] = []

        if let maxD = maxDepth, maxD == 0 {
            if let list = try? FileSystemEngine.listDirectory(at: rootPath, showHidden: includeHidden, includeParentEntry: false) {
                return list.map { item in
                    var copy = item
                    copy.relativeDisplayPath = item.name
                    return copy
                }
            }
            return []
        }

        guard let enumerator = fm.enumerator(atPath: rootPath) else { return [] }
        while let rel = enumerator.nextObject() as? String {
            let depth = rel.split(separator: "/").count - 1
            if let maxD = maxDepth, depth > maxD {
                enumerator.skipDescendants()
                continue
            }
            let components = rel.split(separator: "/")
            if !includeHidden && components.contains(where: { $0.hasPrefix(".") }) {
                continue
            }
            let fullPath = (rootPath as NSString).appendingPathComponent(rel)
            if let item = FileSystemEngine.inspectFileItem(
                atPath: fullPath,
                name: (fullPath as NSString).lastPathComponent,
                relativeDisplayPath: rel
            ) {
                results.append(item)
            }
        }
        return results
    }

    private static func evaluateCandidate(
        _ item: FileItem,
        query: FindFilesQuery,
        matcher: WildcardMaskMatcher,
        now: Date
    ) -> Bool {
        if query.onlyDirectories && !item.isDirectory { return false }
        if query.onlyFiles && item.isDirectory { return false }
        if query.onlyExecutables && !item.isExecutable { return false }
        if !query.findText.isEmpty && item.isDirectory { return false }

        if !matcher.matches(item.name) {
            return false
        }

        if query.dateBetweenEnabled {
            if item.modificationDate < query.dateFrom || item.modificationDate > query.dateTo {
                return false
            }
        }

        if query.notOlderThanEnabled {
            let maxAgeSeconds = Double(query.notOlderThanValue) * query.notOlderThanUnit.secondsMultiplier
            if now.timeIntervalSince(item.modificationDate) > maxAgeSeconds {
                return false
            }
        }

        if query.sizeComparator != .any && !item.isDirectory {
            let threshold = query.sizeValue * query.sizeUnit.rawValue
            switch query.sizeComparator {
            case .any: break
            case .greaterThan:
                if item.size <= threshold { return false }
            case .lessThan:
                if item.size >= threshold { return false }
            case .equalTo:
                if item.size != threshold { return false }
            }
        }

        if !query.findText.isEmpty {
            let contains = fileContainsText(atPath: item.fullPath, query: query)
            if query.invertTextMatch {
                if contains { return false }
            } else {
                if !contains { return false }
            }
        }

        return true
    }

    private static func fileContainsText(atPath path: String, query: FindFilesQuery) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe]) else {
            return false
        }

        if query.textHexMode {
            let hexBytes = parseHexBytes(query.findText)
            guard !hexBytes.isEmpty else { return false }
            return data.range(of: Data(hexBytes)) != nil
        }

        let content = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        guard !content.isEmpty else { return false }

        if query.textUseRegex {
            var opts: NSRegularExpression.Options = []
            if !query.textCaseSensitive { opts.insert(.caseInsensitive) }
            guard let regex = try? NSRegularExpression(pattern: query.findText, options: opts) else {
                return false
            }
            let range = NSRange(content.startIndex..<content.endIndex, in: content)
            return regex.firstMatch(in: content, options: [], range: range) != nil
        }

        if query.textWholeWordsOnly {
            let escaped = NSRegularExpression.escapedPattern(for: query.findText)
            var opts: NSRegularExpression.Options = []
            if !query.textCaseSensitive { opts.insert(.caseInsensitive) }
            guard let regex = try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: opts) else {
                return false
            }
            let range = NSRange(content.startIndex..<content.endIndex, in: content)
            return regex.firstMatch(in: content, options: [], range: range) != nil
        }

        let compareOpts: String.CompareOptions = query.textCaseSensitive ? [] : [.caseInsensitive]
        return content.range(of: query.findText, options: compareOpts) != nil
    }

    private static func parseHexBytes(_ hexString: String) -> [UInt8] {
        let cleaned = hexString
            .replacingOccurrences(of: "0x", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
        var bytes: [UInt8] = []
        var idx = cleaned.startIndex
        while idx < cleaned.endIndex {
            let next = cleaned.index(idx, offsetBy: 2, limitedBy: cleaned.endIndex) ?? cleaned.endIndex
            if let b = UInt8(cleaned[idx..<next], radix: 16) {
                bytes.append(b)
            }
            idx = next
        }
        return bytes
    }

    // MARK: - Duplicate File Grouping

    public static func groupDuplicates(
        items: [FileItem],
        sameName: Bool,
        sameSize: Bool,
        sameContent: Bool
    ) -> [[FileItem]] {
        guard !items.isEmpty else { return [] }

        // Pass 1: Group by (name?, size?)
        var initialBuckets: [String: [FileItem]] = [:]
        for item in items {
            var keyParts: [String] = []
            if sameName {
                keyParts.append(item.name.lowercased())
            }
            if sameSize || sameContent {
                keyParts.append("\(item.size)")
            }
            if keyParts.isEmpty {
                keyParts.append("all")
            }
            let key = keyParts.joined(separator: "::")
            initialBuckets[key, default: []].append(item)
        }

        let candidateGroups = initialBuckets.values.filter { $0.count > 1 }
        if !sameContent {
            return candidateGroups.sorted { $0[0].name < $1[0].name }
        }

        // Pass 2: Verify SHA-256 content hash for candidates with >1 item
        var finalGroups: [[FileItem]] = []
        for group in candidateGroups {
            var hashBuckets: [String: [FileItem]] = [:]
            for item in group {
                if let sha = try? ChecksumEngine.computeChecksum(ofFileAt: item.fullPath, kind: .sha256) {
                    var decorated = item
                    decorated.descriptionComment = "SHA256: \(sha.prefix(12))..."
                    hashBuckets[sha, default: []].append(decorated)
                }
            }
            for (_, dupSet) in hashBuckets where dupSet.count > 1 {
                finalGroups.append(dupSet)
            }
        }

        return finalGroups.sorted { $0[0].name < $1[0].name }
    }
}

// MARK: - Wildcard & Exclusion Matcher (`*.swift;*.md | *Test*`)

public struct WildcardMaskMatcher: Sendable {
    private let includeRegexes: [NSRegularExpression]
    private let excludeRegexes: [NSRegularExpression]

    public init(expression: String, isRegex: Bool = false) {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "*" || trimmed == "*.*" {
            self.includeRegexes = []
            self.excludeRegexes = []
            return
        }

        if isRegex {
            if let rx = try? NSRegularExpression(pattern: trimmed, options: [.caseInsensitive]) {
                self.includeRegexes = [rx]
            } else {
                self.includeRegexes = []
            }
            self.excludeRegexes = []
            return
        }

        let pipeParts = trimmed.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let includePart = String(pipeParts[0]).trimmingCharacters(in: .whitespaces)
        let excludePart = pipeParts.count > 1 ? String(pipeParts[1]).trimmingCharacters(in: .whitespaces) : ""

        self.includeRegexes = Self.compileWildcardList(includePart)
        self.excludeRegexes = Self.compileWildcardList(excludePart)
    }

    public func matches(_ fileName: String) -> Bool {
        let range = NSRange(fileName.startIndex..<fileName.endIndex, in: fileName)
        for ex in excludeRegexes {
            if ex.firstMatch(in: fileName, options: [], range: range) != nil {
                return false
            }
        }
        if includeRegexes.isEmpty {
            return true
        }
        for inc in includeRegexes {
            if inc.firstMatch(in: fileName, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }

    private static func compileWildcardList(_ listStr: String) -> [NSRegularExpression] {
        guard !listStr.isEmpty else { return [] }
        let tokens = listStr
            .components(separatedBy: CharacterSet(charactersIn: ";, "))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return tokens.compactMap { token in
            if token == "*.*" || token == "*" {
                return try? NSRegularExpression(pattern: "^.*$", options: [.caseInsensitive])
            }
            var pattern = "^"
            for ch in token {
                switch ch {
                case "*": pattern.append(".*")
                case "?": pattern.append(".")
                case ".", "+", "(", ")", "[", "]", "{", "}", "^", "$", "\\", "|":
                    pattern.append("\\\(ch)")
                default:
                    pattern.append(ch)
                }
            }
            pattern.append("$")
            return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }
    }
}
