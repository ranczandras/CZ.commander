import Foundation

// MARK: - 1. Synchronize Directories Engine

public enum SyncActionDirection: String, CaseIterable, Codable, Sendable {
    case copyLeftToRight = "->"
    case equal = "=="
    case unequal = "!="
    case copyRightToLeft = "<-"
    case deleteRight = "X->"
    case skip = " "
}

public struct SyncOptions: Codable, Sendable {
    public var includeSubdirs: Bool
    public var compareByContent: Bool
    public var ignoreDate: Bool
    public var asymmetric: Bool
    public var fileMask: String

    public init(
        includeSubdirs: Bool = true,
        compareByContent: Bool = false,
        ignoreDate: Bool = false,
        asymmetric: Bool = false,
        fileMask: String = "*.*"
    ) {
        self.includeSubdirs = includeSubdirs
        self.compareByContent = compareByContent
        self.ignoreDate = ignoreDate
        self.asymmetric = asymmetric
        self.fileMask = fileMask
    }
}

public struct SyncComparisonEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let relativePath: String
    public let leftItem: FileItem?
    public let rightItem: FileItem?
    public var direction: SyncActionDirection

    public var isDuplicate: Bool {
        leftItem != nil && rightItem != nil
    }

    public var isSingle: Bool {
        (leftItem != nil && rightItem == nil) || (leftItem == nil && rightItem != nil)
    }
}

public struct SyncExecutionResult: Sendable {
    public let copiedLeftToRight: Int
    public let copiedRightToLeft: Int
    public let deletedFromRight: Int
    public let totalBytesTransferred: Int64
}

public enum DirectorySyncEngine {
    public static func compareDirectories(
        leftRoot: String,
        rightRoot: String,
        options: SyncOptions = SyncOptions()
    ) -> [SyncComparisonEntry] {
        let stdLeft = (leftRoot as NSString).standardizingPath
        let stdRight = (rightRoot as NSString).standardizingPath
        let matcher = WildcardMaskMatcher(expression: options.fileMask)

        let leftMap = collectRelativeFileMap(root: stdLeft, recursive: options.includeSubdirs, matcher: matcher)
        let rightMap = collectRelativeFileMap(root: stdRight, recursive: options.includeSubdirs, matcher: matcher)

        let allKeys = Set(leftMap.keys).union(rightMap.keys).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }

        var entries: [SyncComparisonEntry] = []
        entries.reserveCapacity(allKeys.count)

        for relPath in allKeys {
            let lItem = leftMap[relPath]
            let rItem = rightMap[relPath]
            let direction = determineDirection(
                left: lItem,
                right: rItem,
                options: options
            )
            entries.append(
                SyncComparisonEntry(
                    id: relPath,
                    relativePath: relPath,
                    leftItem: lItem,
                    rightItem: rItem,
                    direction: direction
                )
            )
        }

        return entries
    }

    private static func collectRelativeFileMap(
        root: String,
        recursive: Bool,
        matcher: WildcardMaskMatcher
    ) -> [String: FileItem] {
        var map: [String: FileItem] = [:]
        if recursive {
            let items = FileSystemEngine.listBranchView(at: root, showHidden: false)
            for item in items where !item.isParentDirectoryEntry && !item.isDirectory {
                if matcher.matches(item.name), let rel = item.relativeDisplayPath {
                    map[rel] = item
                }
            }
        } else {
            if let items = try? FileSystemEngine.listDirectory(at: root, showHidden: false, includeParentEntry: false) {
                for item in items where !item.isDirectory {
                    if matcher.matches(item.name) {
                        map[item.name] = item
                    }
                }
            }
        }
        return map
    }

    private static func determineDirection(
        left: FileItem?,
        right: FileItem?,
        options: SyncOptions
    ) -> SyncActionDirection {
        switch (left, right) {
        case (.some, .none):
            return .copyLeftToRight
        case (.none, .some):
            return options.asymmetric ? .deleteRight : .copyRightToLeft
        case (.some(let l), .some(let r)):
            if options.compareByContent {
                if l.size != r.size {
                    return determineByTimestampOrUnequal(left: l, right: r, ignoreDate: options.ignoreDate, asymmetric: options.asymmetric)
                }
                let lHash = try? ChecksumEngine.computeChecksum(ofFileAt: l.fullPath, kind: .sha256)
                let rHash = try? ChecksumEngine.computeChecksum(ofFileAt: r.fullPath, kind: .sha256)
                if lHash != nil && lHash == rHash {
                    return .equal
                }
                return determineByTimestampOrUnequal(left: l, right: r, ignoreDate: options.ignoreDate, asymmetric: options.asymmetric)
            } else {
                if options.ignoreDate {
                    return (l.size == r.size) ? .equal : .unequal
                }
                let timeDiff = l.modificationDate.timeIntervalSince(r.modificationDate)
                if abs(timeDiff) <= 2.0 && l.size == r.size {
                    return .equal
                }
                if timeDiff > 2.0 {
                    return .copyLeftToRight
                } else if timeDiff < -2.0 {
                    return options.asymmetric ? .copyLeftToRight : .copyRightToLeft
                } else {
                    return .unequal
                }
            }
        case (.none, .none):
            return .equal
        }
    }

    private static func determineByTimestampOrUnequal(
        left: FileItem,
        right: FileItem,
        ignoreDate: Bool,
        asymmetric: Bool
    ) -> SyncActionDirection {
        if ignoreDate { return .unequal }
        let diff = left.modificationDate.timeIntervalSince(right.modificationDate)
        if diff > 2.0 { return .copyLeftToRight }
        if diff < -2.0 { return asymmetric ? .copyLeftToRight : .copyRightToLeft }
        return .unequal
    }

    public static func executeSync(
        entries: [SyncComparisonEntry],
        leftRoot: String,
        rightRoot: String
    ) throws -> SyncExecutionResult {
        let fm = FileManager.default
        var copiedLR = 0
        var copiedRL = 0
        var deletedR = 0
        var transferredBytes: Int64 = 0

        for entry in entries {
            let leftTarget = (leftRoot as NSString).appendingPathComponent(entry.relativePath)
            let rightTarget = (rightRoot as NSString).appendingPathComponent(entry.relativePath)

            switch entry.direction {
            case .copyLeftToRight:
                guard let lItem = entry.leftItem else { continue }
                let parentDir = (rightTarget as NSString).deletingLastPathComponent
                if !fm.fileExists(atPath: parentDir) {
                    try fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
                }
                if fm.fileExists(atPath: rightTarget) {
                    try FileSystemEngine.removeExistingUnlockingIfNeeded(atPath: rightTarget)
                }
                try fm.copyItem(atPath: lItem.fullPath, toPath: rightTarget)
                if let attrs = try? fm.attributesOfItem(atPath: lItem.fullPath),
                   let mod = attrs[.modificationDate] {
                    try? fm.setAttributes([.modificationDate: mod], ofItemAtPath: rightTarget)
                }
                copiedLR += 1
                transferredBytes += lItem.size

            case .copyRightToLeft:
                guard let rItem = entry.rightItem else { continue }
                let parentDir = (leftTarget as NSString).deletingLastPathComponent
                if !fm.fileExists(atPath: parentDir) {
                    try fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
                }
                if fm.fileExists(atPath: leftTarget) {
                    try FileSystemEngine.removeExistingUnlockingIfNeeded(atPath: leftTarget)
                }
                try fm.copyItem(atPath: rItem.fullPath, toPath: leftTarget)
                if let attrs = try? fm.attributesOfItem(atPath: rItem.fullPath),
                   let mod = attrs[.modificationDate] {
                    try? fm.setAttributes([.modificationDate: mod], ofItemAtPath: leftTarget)
                }
                copiedRL += 1
                transferredBytes += rItem.size

            case .deleteRight:
                if fm.fileExists(atPath: rightTarget) {
                    try FileSystemEngine.removeExistingUnlockingIfNeeded(atPath: rightTarget)
                    deletedR += 1
                }

            case .equal, .unequal, .skip:
                break
            }
        }

        return SyncExecutionResult(
            copiedLeftToRight: copiedLR,
            copiedRightToLeft: copiedRL,
            deletedFromRight: deletedR,
            totalBytesTransferred: transferredBytes
        )
    }
}

// MARK: - 2. Compare By Content Engine (Text Side-by-Side LCS + Binary Hex Diff)

public enum DiffLineKind: String, Codable, Sendable {
    case equal = "equal"
    case modified = "modified"
    case insertedLeft = "insertedLeft"
    case insertedRight = "insertedRight"
}

public struct SideBySideDiffRow: Identifiable, Hashable, Sendable {
    public let id: Int
    public let leftLineNumber: Int?
    public let rightLineNumber: Int?
    public var leftText: String
    public var rightText: String
    public let kind: DiffLineKind
}

public struct BinaryDiffMismatch: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let byteOffset: Int64
    public let leftByte: UInt8?
    public let rightByte: UInt8?
}

public struct ContentComparisonReport: Sendable {
    public let areIdentical: Bool
    public let isBinaryComparison: Bool
    public let rows: [SideBySideDiffRow]
    public let differenceRowIndices: [Int]
    public let binaryMismatches: [BinaryDiffMismatch]
}

public enum CompareByContentEngine {
    public static func compareFiles(
        leftPath: String,
        rightPath: String,
        ignoreCase: Bool = false,
        ignoreRepeatedSpaces: Bool = false,
        forceBinaryMode: Bool = false
    ) throws -> ContentComparisonReport {
        let leftData = try Data(contentsOf: URL(fileURLWithPath: leftPath), options: [.mappedIfSafe])
        let rightData = try Data(contentsOf: URL(fileURLWithPath: rightPath), options: [.mappedIfSafe])

        let isBinary = forceBinaryMode || looksLikeBinary(leftData) || looksLikeBinary(rightData)
        if isBinary {
            return compareBinary(leftData: leftData, rightData: rightData)
        }

        let leftStr = String(data: leftData, encoding: .utf8) ?? String(data: leftData, encoding: .isoLatin1) ?? ""
        let rightStr = String(data: rightData, encoding: .utf8) ?? String(data: rightData, encoding: .isoLatin1) ?? ""

        return compareTextStrings(
            leftText: leftStr,
            rightText: rightStr,
            ignoreCase: ignoreCase,
            ignoreRepeatedSpaces: ignoreRepeatedSpaces
        )
    }

    public static func compareTextStrings(
        leftText: String,
        rightText: String,
        ignoreCase: Bool = false,
        ignoreRepeatedSpaces: Bool = false
    ) -> ContentComparisonReport {
        let leftLines = splitLines(leftText)
        let rightLines = splitLines(rightText)

        func normalize(_ s: String) -> String {
            var res = s
            if ignoreRepeatedSpaces {
                res = res.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
            }
            if ignoreCase {
                res = res.lowercased()
            }
            return res
        }

        let normLeft = leftLines.map(normalize)
        let normRight = rightLines.map(normalize)

        let m = leftLines.count
        let n = rightLines.count

        // LCS DP table (for huge files > 4000 lines, use anchored greedy matching)
        var rows: [SideBySideDiffRow] = []
        if m * n <= 16_000_000 {
            var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
            for i in stride(from: m - 1, through: 0, by: -1) {
                for j in stride(from: n - 1, through: 0, by: -1) {
                    if normLeft[i] == normRight[j] {
                        dp[i][j] = 1 + dp[i + 1][j + 1]
                    } else {
                        dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                    }
                }
            }

            var i = 0
            var j = 0
            var rawOps: [(Int?, Int?, String, String, DiffLineKind)] = []

            while i < m && j < n {
                if normLeft[i] == normRight[j] {
                    rawOps.append((i + 1, j + 1, leftLines[i], rightLines[j], .equal))
                    i += 1
                    j += 1
                } else if dp[i + 1][j] >= dp[i][j + 1] {
                    rawOps.append((i + 1, nil, leftLines[i], "", .insertedLeft))
                    i += 1
                } else {
                    rawOps.append((nil, j + 1, "", rightLines[j], .insertedRight))
                    j += 1
                }
            }
            while i < m {
                rawOps.append((i + 1, nil, leftLines[i], "", .insertedLeft))
                i += 1
            }
            while j < n {
                rawOps.append((nil, j + 1, "", rightLines[j], .insertedRight))
                j += 1
            }

            // Pair consecutive insertedLeft + insertedRight into `.modified` side-by-side rows
            var idx = 0
            var rowId = 0
            while idx < rawOps.count {
                let current = rawOps[idx]
                if current.4 == .insertedLeft && idx + 1 < rawOps.count && rawOps[idx + 1].4 == .insertedRight {
                    let next = rawOps[idx + 1]
                    rows.append(
                        SideBySideDiffRow(
                            id: rowId,
                            leftLineNumber: current.0,
                            rightLineNumber: next.1,
                            leftText: current.2,
                            rightText: next.3,
                            kind: .modified
                        )
                    )
                    idx += 2
                } else {
                    rows.append(
                        SideBySideDiffRow(
                            id: rowId,
                            leftLineNumber: current.0,
                            rightLineNumber: current.1,
                            leftText: current.2,
                            rightText: current.3,
                            kind: current.4
                        )
                    )
                    idx += 1
                }
                rowId += 1
            }
        } else {
            let maxCount = max(m, n)
            for idx in 0..<maxCount {
                let lLine = idx < m ? leftLines[idx] : nil
                let rLine = idx < n ? rightLines[idx] : nil
                let kind: DiffLineKind
                if let l = lLine, let r = rLine {
                    kind = (normalize(l) == normalize(r)) ? .equal : .modified
                } else if lLine != nil {
                    kind = .insertedLeft
                } else {
                    kind = .insertedRight
                }
                rows.append(
                    SideBySideDiffRow(
                        id: idx,
                        leftLineNumber: lLine != nil ? idx + 1 : nil,
                        rightLineNumber: rLine != nil ? idx + 1 : nil,
                        leftText: lLine ?? "",
                        rightText: rLine ?? "",
                        kind: kind
                    )
                )
            }
        }

        let diffIndices = rows.enumerated().compactMap { $0.element.kind != .equal ? $0.offset : nil }
        return ContentComparisonReport(
            areIdentical: diffIndices.isEmpty,
            isBinaryComparison: false,
            rows: rows,
            differenceRowIndices: diffIndices,
            binaryMismatches: []
        )
    }

    private static func compareBinary(leftData: Data, rightData: Data) -> ContentComparisonReport {
        let identical = leftData == rightData
        var mismatches: [BinaryDiffMismatch] = []
        var rows: [SideBySideDiffRow] = []

        let lBytes = Array(leftData)
        let rBytes = Array(rightData)
        let maxLen = max(lBytes.count, rBytes.count)

        let bytesPerRow = 16
        let totalRows = min(2000, (maxLen + bytesPerRow - 1) / bytesPerRow)

        for rowIdx in 0..<totalRows {
            let offset = rowIdx * bytesPerRow
            var lHex: [String] = []
            var rHex: [String] = []
            var rowDiffers = false

            for b in 0..<bytesPerRow {
                let pos = offset + b
                let lb: UInt8? = pos < lBytes.count ? lBytes[pos] : nil
                let rb: UInt8? = pos < rBytes.count ? rBytes[pos] : nil
                if lb != rb {
                    rowDiffers = true
                    if mismatches.count < 5000 {
                        mismatches.append(
                            BinaryDiffMismatch(
                                id: Int64(pos),
                                byteOffset: Int64(pos),
                                leftByte: lb,
                                rightByte: rb
                            )
                        )
                    }
                }
                lHex.append(lb.map { String(format: "%02X", $0) } ?? "  ")
                rHex.append(rb.map { String(format: "%02X", $0) } ?? "  ")
            }

            let addr = String(format: "%08X:", offset)
            rows.append(
                SideBySideDiffRow(
                    id: rowIdx,
                    leftLineNumber: rowIdx + 1,
                    rightLineNumber: rowIdx + 1,
                    leftText: "\(addr) \(lHex.joined(separator: " "))",
                    rightText: "\(addr) \(rHex.joined(separator: " "))",
                    kind: rowDiffers ? .modified : .equal
                )
            )
        }

        let diffIndices = rows.enumerated().compactMap { $0.element.kind != .equal ? $0.offset : nil }
        return ContentComparisonReport(
            areIdentical: identical,
            isBinaryComparison: true,
            rows: rows,
            differenceRowIndices: diffIndices,
            binaryMismatches: mismatches
        )
    }

    private static func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    private static func looksLikeBinary(_ data: Data) -> Bool {
        let sampleCount = min(4096, data.count)
        guard sampleCount > 0 else { return false }
        return data.prefix(sampleCount).contains(0)
    }

    // MARK: - 3. Compare Directories (Shift+F2)

    /// Returns `(selectedInLeft, selectedInRight)` containing IDs of files that are missing or newer than in the other panel
    public static func comparePanelItems(
        leftItems: [FileItem],
        rightItems: [FileItem]
    ) -> (Set<String>, Set<String>) {
        var leftByName: [String: FileItem] = [:]
        var rightByName: [String: FileItem] = [:]

        for item in leftItems where !item.isParentDirectoryEntry && !item.isDirectory {
            leftByName[item.name.lowercased()] = item
        }
        for item in rightItems where !item.isParentDirectoryEntry && !item.isDirectory {
            rightByName[item.name.lowercased()] = item
        }

        var selectLeft: Set<String> = []
        var selectRight: Set<String> = []

        for (nameKey, lItem) in leftByName {
            if let rItem = rightByName[nameKey] {
                if lItem.modificationDate.timeIntervalSince(rItem.modificationDate) > 2.0 {
                    selectLeft.insert(lItem.id)
                } else if lItem.size != rItem.size && abs(lItem.modificationDate.timeIntervalSince(rItem.modificationDate)) <= 2.0 {
                    selectLeft.insert(lItem.id)
                }
            } else {
                selectLeft.insert(lItem.id)
            }
        }

        for (nameKey, rItem) in rightByName {
            if let lItem = leftByName[nameKey] {
                if rItem.modificationDate.timeIntervalSince(lItem.modificationDate) > 2.0 {
                    selectRight.insert(rItem.id)
                } else if rItem.size != lItem.size && abs(rItem.modificationDate.timeIntervalSince(lItem.modificationDate)) <= 2.0 {
                    selectRight.insert(rItem.id)
                }
            } else {
                selectRight.insert(rItem.id)
            }
        }

        return (selectLeft, selectRight)
    }
}
