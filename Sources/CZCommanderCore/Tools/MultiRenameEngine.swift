import Foundation

public enum MultiRenameCaseMode: String, CaseIterable, Codable, Sendable {
    case unchanged = "unchanged"
    case allLowercase = "allLowercase"
    case allUppercase = "allUppercase"
    case firstLetterUppercase = "firstLetterUppercase"
    case titleCaseWords = "titleCaseWords"

    public var displayName: String {
        switch self {
        case .unchanged:
            return "Unchanged"
        case .allLowercase:
            return "all lowercase"
        case .allUppercase:
            return "ALL UPPERCASE"
        case .firstLetterUppercase:
            return "First letter uppercase"
        case .titleCaseWords:
            return "First Of Each Word Uppercase"
        }
    }
}

public struct MultiRenameConfig: Codable, Hashable, Sendable {
    public var nameMask: String
    public var extensionMask: String
    public var searchFor: String
    public var replaceWith: String
    public var caseSensitiveSearch: Bool
    public var replaceOnlyOnce: Bool
    public var useRegex: Bool
    public var caseMode: MultiRenameCaseMode
    public var counterStart: Int
    public var counterStep: Int
    public var counterDigits: Int
    public var applySearchReplaceToExtension: Bool

    public init(
        nameMask: String = "[N]",
        extensionMask: String = "[E]",
        searchFor: String = "",
        replaceWith: String = "",
        caseSensitiveSearch: Bool = false,
        replaceOnlyOnce: Bool = false,
        useRegex: Bool = false,
        caseMode: MultiRenameCaseMode = .unchanged,
        counterStart: Int = 1,
        counterStep: Int = 1,
        counterDigits: Int = 3,
        applySearchReplaceToExtension: Bool = false
    ) {
        self.nameMask = nameMask
        self.extensionMask = extensionMask
        self.searchFor = searchFor
        self.replaceWith = replaceWith
        self.caseSensitiveSearch = caseSensitiveSearch
        self.replaceOnlyOnce = replaceOnlyOnce
        self.useRegex = useRegex
        self.caseMode = caseMode
        self.counterStart = counterStart
        self.counterStep = counterStep
        self.counterDigits = max(1, min(12, counterDigits))
        self.applySearchReplaceToExtension = applySearchReplaceToExtension
    }
}

public struct MultiRenamePreviewRow: Identifiable, Hashable, Sendable {
    public let id: String
    public let item: FileItem
    public let originalName: String
    public let proposedName: String
    public let hasConflict: Bool
    public let conflictReason: String?

    public var isChanged: Bool {
        originalName != proposedName
    }
}

public struct MultiRenameBatchRecord: Sendable {
    public let timestamp: Date
    /// Array of `(oldFullPath, newFullPath)`
    public let operations: [(String, String)]
}

public enum MultiRenameEngine {
    public static func generatePreview(
        items: [FileItem],
        config: MultiRenameConfig
    ) -> [MultiRenamePreviewRow] {
        let validItems = items.filter { !$0.isParentDirectoryEntry }
        var proposedList: [(FileItem, String)] = []
        var counts: [String: Int] = [:]

        for (index, item) in validItems.enumerated() {
            let newName = computeNewName(for: item, index: index, config: config)
            proposedList.append((item, newName))
            counts[newName.lowercased(), default: 0] += 1
        }

        let inputPaths = Set(validItems.map { ($0.fullPath as NSString).standardizingPath.lowercased() })
        let fm = FileManager.default

        return proposedList.map { (item, proposed) in
            let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
            var conflict = false
            var reason: String? = nil

            if trimmed.isEmpty || trimmed == "." || trimmed == ".." || trimmed.contains("/") {
                conflict = true
                reason = "Invalid filename"
            } else if (counts[trimmed.lowercased()] ?? 0) > 1 {
                conflict = true
                reason = "Duplicate target name in batch"
            } else {
                let dir = (item.fullPath as NSString).deletingLastPathComponent
                let targetFull = ((dir as NSString).appendingPathComponent(trimmed) as NSString).standardizingPath
                if !inputPaths.contains(targetFull.lowercased()) && fm.fileExists(atPath: targetFull) {
                    conflict = true
                    reason = "File already exists on disk"
                }
            }

            return MultiRenamePreviewRow(
                id: item.id,
                item: item,
                originalName: item.name,
                proposedName: trimmed,
                hasConflict: conflict,
                conflictReason: reason
            )
        }
    }

    public static func computeNewName(
        for item: FileItem,
        index: Int,
        config: MultiRenameConfig
    ) -> String {
        let rawStem = expandMask(
            config.nameMask,
            for: item,
            index: index,
            config: config
        )
        let rawExt = expandMask(
            config.extensionMask,
            for: item,
            index: index,
            config: config
        )

        let processedStem: String
        let processedExt: String

        if config.applySearchReplaceToExtension {
            let combined = rawExt.isEmpty ? rawStem : "\(rawStem).\(rawExt)"
            let replaced = applySearchReplace(to: combined, config: config)
            let cased = applyCaseMode(to: replaced, mode: config.caseMode, isFullFilename: true)
            return cased
        } else {
            processedStem = applyCaseMode(
                to: applySearchReplace(to: rawStem, config: config),
                mode: config.caseMode,
                isFullFilename: false
            )
            processedExt = applyCaseMode(
                to: rawExt,
                mode: config.caseMode,
                isFullFilename: false
            )
            if processedExt.isEmpty {
                return processedStem
            }
            return "\(processedStem).\(processedExt)"
        }
    }

    // MARK: - Token Expansion

    public static func expandMask(
        _ mask: String,
        for item: FileItem,
        index: Int,
        config: MultiRenameConfig
    ) -> String {
        let stem = item.stem
        let ext = item.ext
        let dirPath = (item.fullPath as NSString).deletingLastPathComponent
        let parentName = (dirPath as NSString).lastPathComponent
        let grandParentName = ((dirPath as NSString).deletingLastPathComponent as NSString).lastPathComponent

        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: item.modificationDate)
        let year4 = String(format: "%04d", comps.year ?? 2026)
        let year2 = String(year4.suffix(2))
        let month2 = String(format: "%02d", comps.month ?? 1)
        let day2 = String(format: "%02d", comps.day ?? 1)
        let hour2 = String(format: "%02d", comps.hour ?? 0)
        let min2 = String(format: "%02d", comps.minute ?? 0)
        let sec2 = String(format: "%02d", comps.second ?? 0)

        var output = ""
        var i = mask.startIndex
        while i < mask.endIndex {
            let ch = mask[i]
            if ch == "[", let closeIdx = mask[i...].firstIndex(of: "]") {
                let tokenStart = mask.index(after: i)
                let token = String(mask[tokenStart..<closeIdx])
                if let expanded = evaluateToken(
                    token,
                    stem: stem,
                    ext: ext,
                    parentName: parentName,
                    grandParentName: grandParentName,
                    year4: year4,
                    year2: year2,
                    month2: month2,
                    day2: day2,
                    hour2: hour2,
                    min2: min2,
                    sec2: sec2,
                    index: index,
                    config: config
                ) {
                    output.append(expanded)
                    i = mask.index(after: closeIdx)
                    continue
                }
            }
            output.append(ch)
            i = mask.index(after: i)
        }
        return output
    }

    private static func evaluateToken(
        _ token: String,
        stem: String,
        ext: String,
        parentName: String,
        grandParentName: String,
        year4: String,
        year2: String,
        month2: String,
        day2: String,
        hour2: String,
        min2: String,
        sec2: String,
        index: Int,
        config: MultiRenameConfig
    ) -> String? {
        if token == "N" { return stem }
        if token == "E" { return ext }
        if token == "P" { return parentName }
        if token == "G" { return grandParentName }
        if token == "Y" { return year4 }
        if token == "y" { return year2 }
        if token == "M" { return month2 }
        if token == "D" { return day2 }
        if token == "YMD" { return "\(year4)\(month2)\(day2)" }
        if token == "h" { return hour2 }
        if token == "m" { return min2 }
        if token == "s" { return sec2 }
        if token == "hms" { return "\(hour2)\(min2)\(sec2)" }

        if token == "C" {
            let val = config.counterStart + index * config.counterStep
            return String(format: "%0\(config.counterDigits)d", val)
        }

        // Inline counter: [C10+5:3] or [C1:4]
        if token.hasPrefix("C") && token.count > 1 {
            let spec = String(token.dropFirst())
            var start = config.counterStart
            var step = config.counterStep
            var digits = config.counterDigits

            let partsColon = spec.split(separator: ":", maxSplits: 1)
            if partsColon.count == 2, let d = Int(partsColon[1]) {
                digits = max(1, min(12, d))
            }
            let leftPart = String(partsColon[0])
            let partsPlus = leftPart.split(separator: "+", maxSplits: 1)
            if let s = Int(partsPlus[0]) {
                start = s
            }
            if partsPlus.count == 2, let st = Int(partsPlus[1]) {
                step = st
            }
            let val = start + index * step
            return String(format: "%0\(digits)d", val)
        }

        // Substring slicing on [N...] or [E...]
        if token.hasPrefix("N") && token.count > 1 {
            return sliceString(stem, spec: String(token.dropFirst()))
        }
        if token.hasPrefix("E") && token.count > 1 {
            return sliceString(ext, spec: String(token.dropFirst()))
        }

        return nil
    }

    /// Total Commander 1-based substring slice:
    /// - `1-5`: chars 1 through 5 inclusive
    /// - `2,4`: 4 chars starting at position 2
    /// - `3-`: from char 3 to end
    /// - `-5`: last 5 chars
    /// - `2--3`: from char 2 to 3rd from end
    public static func sliceString(_ source: String, spec: String) -> String {
        let chars = Array(source)
        guard !chars.isEmpty else { return "" }
        let count = chars.count

        // [N2,4] -> start at 2 (1-based), length 4
        if spec.contains(",") {
            let parts = spec.split(separator: ",", maxSplits: 1)
            guard parts.count == 2,
                  let rawStart = Int(parts[0]),
                  let length = Int(parts[1]),
                  length > 0 else {
                return ""
            }
            let startIdx: Int
            if rawStart < 0 {
                startIdx = max(0, count + rawStart)
            } else {
                startIdx = max(0, rawStart - 1)
            }
            guard startIdx < count else { return "" }
            let endIdx = min(count, startIdx + length)
            return String(chars[startIdx..<endIdx])
        }

        // [N-5] -> last 5 chars
        if spec.hasPrefix("-"), let lastCount = Int(spec.dropFirst()), lastCount > 0 {
            let startIdx = max(0, count - lastCount)
            return String(chars[startIdx..<count])
        }

        // [N2--3] -> from 2 to 3rd from end
        if let doubleDash = spec.range(of: "--") {
            let startStr = String(spec[..<doubleDash.lowerBound])
            let endOffsetStr = String(spec[doubleDash.upperBound...])
            guard let start1 = Int(startStr), let endBack = Int(endOffsetStr) else {
                return ""
            }
            let startIdx = max(0, start1 - 1)
            let endIdx = count - endBack
            guard startIdx <= endIdx && startIdx < count && endIdx >= 0 else { return "" }
            return String(chars[startIdx...min(count - 1, endIdx)])
        }

        // [N3-] -> from 3 to end
        if spec.hasSuffix("-"), let start1 = Int(spec.dropLast()) {
            let startIdx = max(0, start1 - 1)
            guard startIdx < count else { return "" }
            return String(chars[startIdx..<count])
        }

        // [N1-5] -> 1 to 5 inclusive
        if let dash = spec.firstIndex(of: "-") {
            let sStr = String(spec[..<dash])
            let eStr = String(spec[spec.index(after: dash)...])
            guard let s1 = Int(sStr), let e1 = Int(eStr) else { return "" }
            let startIdx = max(0, s1 - 1)
            let endIdx = min(count - 1, e1 - 1)
            guard startIdx <= endIdx && startIdx < count && endIdx >= 0 else { return "" }
            return String(chars[startIdx...endIdx])
        }

        // Single character [N3]
        if let pos = Int(spec), pos >= 1, pos <= count {
            return String(chars[pos - 1])
        }

        return ""
    }

    // MARK: - Search & Replace

    public static func applySearchReplace(to input: String, config: MultiRenameConfig) -> String {
        guard !config.searchFor.isEmpty else { return input }

        if config.useRegex {
            var options: NSRegularExpression.Options = []
            if !config.caseSensitiveSearch {
                options.insert(.caseInsensitive)
            }
            guard let regex = try? NSRegularExpression(pattern: config.searchFor, options: options) else {
                return input
            }
            let nsRange = NSRange(input.startIndex..<input.endIndex, in: input)
            if config.replaceOnlyOnce {
                if let match = regex.firstMatch(in: input, options: [], range: nsRange),
                   let swiftRange = Range(match.range, in: input) {
                    let replacement = regex.replacementString(for: match, in: input, offset: 0, template: config.replaceWith)
                    var copy = input
                    copy.replaceSubrange(swiftRange, with: replacement)
                    return copy
                }
                return input
            } else {
                return regex.stringByReplacingMatches(in: input, options: [], range: nsRange, withTemplate: config.replaceWith)
            }
        }

        // Standard Total Commander multi-token `a|b|c` search & replace
        let searchTerms = config.searchFor.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let replaceTerms = config.replaceWith.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        var current = input
        let compareOptions: String.CompareOptions = config.caseSensitiveSearch ? [] : [.caseInsensitive]

        for (i, term) in searchTerms.enumerated() where !term.isEmpty {
            let replacement: String
            if i < replaceTerms.count {
                replacement = replaceTerms[i]
            } else if let last = replaceTerms.last {
                replacement = last
            } else {
                replacement = ""
            }

            if config.replaceOnlyOnce {
                if let range = current.range(of: term, options: compareOptions) {
                    current.replaceSubrange(range, with: replacement)
                }
            } else {
                current = current.replacingOccurrences(of: term, with: replacement, options: compareOptions)
            }
        }
        return current
    }

    // MARK: - Case Conversion

    public static func applyCaseMode(
        to input: String,
        mode: MultiRenameCaseMode,
        isFullFilename: Bool
    ) -> String {
        guard !input.isEmpty else { return input }
        switch mode {
        case .unchanged:
            return input
        case .allLowercase:
            return input.lowercased()
        case .allUppercase:
            return input.uppercased()
        case .firstLetterUppercase:
            let lower = input.lowercased()
            return lower.prefix(1).uppercased() + lower.dropFirst()
        case .titleCaseWords:
            if isFullFilename, let dot = input.lastIndex(of: "."), dot != input.startIndex {
                let stemPart = String(input[..<dot]).capitalized
                let extPart = String(input[input.index(after: dot)...]).lowercased()
                return "\(stemPart).\(extPart)"
            }
            return input.capitalized
        }
    }

    // MARK: - Two-Phase Safe Execution & Undo

    public static func executeRename(
        previewRows: [MultiRenamePreviewRow]
    ) throws -> MultiRenameBatchRecord {
        let actionable = previewRows.filter { $0.isChanged }
        if actionable.contains(where: { $0.hasConflict }) {
            throw NSError(
                domain: "CZCommander.MultiRename",
                code: 409,
                userInfo: [NSLocalizedDescriptionKey: "Cannot execute rename batch while conflicts exist."]
            )
        }

        let fm = FileManager.default
        let batchID = UUID().uuidString
        var tempMappings: [(originalPath: String, tempPath: String, finalPath: String)] = []

        // Phase 1: Move all to unique temporary names so cyclic renames or case-only renames on APFS never collide
        for (idx, row) in actionable.enumerated() {
            let oldPath = row.item.fullPath
            let dir = (oldPath as NSString).deletingLastPathComponent
            let tempPath = (dir as NSString).appendingPathComponent(".tc_mrename_\(batchID)_\(idx)")
            let finalPath = (dir as NSString).appendingPathComponent(row.proposedName)
            try fm.moveItem(atPath: oldPath, toPath: tempPath)
            tempMappings.append((oldPath, tempPath, finalPath))
        }

        // Phase 2: Move from temporary names to final target names
        var completedPairs: [(String, String)] = []
        for mapping in tempMappings {
            try fm.moveItem(atPath: mapping.tempPath, toPath: mapping.finalPath)
            completedPairs.append((mapping.originalPath, mapping.finalPath))
        }

        return MultiRenameBatchRecord(timestamp: Date(), operations: completedPairs)
    }

    public static func undoRename(batch: MultiRenameBatchRecord) throws {
        let fm = FileManager.default
        let undoID = UUID().uuidString
        var tempSteps: [(tempPath: String, originalPath: String)] = []

        for (idx, pair) in batch.operations.enumerated().reversed() {
            let (originalPath, currentPath) = pair
            guard fm.fileExists(atPath: currentPath) else { continue }
            let dir = (currentPath as NSString).deletingLastPathComponent
            let tempPath = (dir as NSString).appendingPathComponent(".tc_mundo_\(undoID)_\(idx)")
            try fm.moveItem(atPath: currentPath, toPath: tempPath)
            tempSteps.append((tempPath, originalPath))
        }

        for step in tempSteps {
            try fm.moveItem(atPath: step.tempPath, toPath: step.originalPath)
        }
    }
}
