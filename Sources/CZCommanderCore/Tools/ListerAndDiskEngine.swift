import Foundation
import Darwin

public enum ListerMode: Int, CaseIterable, Codable, Sendable {
    case text = 1
    case binary = 2
    case hex = 3
    case multimedia = 4

    public var displayName: String {
        switch self {
        case .text: return "1: Text"
        case .binary: return "2: Binary"
        case .hex: return "3: Hex"
        case .multimedia: return "4: Multimedia / Image / PDF"
        }
    }
}

public enum TextEncodingOption: String, CaseIterable, Codable, Sendable {
    case utf8 = "UTF-8"
    case isoLatin1 = "ISO-8859-1"
    case windows1250 = "Windows-1250 (Central EU)"
    case utf16 = "UTF-16"
    case ascii = "ASCII"

    public var stringEncoding: String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .isoLatin1: return .isoLatin1
        case .windows1250: return .windowsCP1250
        case .utf16: return .utf16
        case .ascii: return .ascii
        }
    }
}

public struct HexDumpRow: Identifiable, Hashable, Sendable {
    public let id: Int
    public let offsetHex: String
    public let hexColumns: String
    public let asciiColumns: String
}

public enum ListerEngine {
    public static func loadFilePreviewData(atPath path: String, maxBytes: Int = 2 * 1024 * 1024) throws -> (Data, Int64) {
        let url = URL(fileURLWithPath: path)
        let attr = try? FileManager.default.attributesOfItem(atPath: path)
        let totalSize = (attr?[.size] as? NSNumber)?.int64Value ?? 0

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            let fallback = try Data(contentsOf: url, options: [.mappedIfSafe])
            return (fallback.prefix(maxBytes), Int64(fallback.count))
        }
        defer { try? handle.close() }
        let chunk = (try? handle.read(upToCount: maxBytes)) ?? Data()
        return (chunk, totalSize)
    }

    public static func decodeText(data: Data, encoding: TextEncodingOption = .utf8) -> String {
        if let decoded = String(data: data, encoding: encoding.stringEncoding) {
            return decoded
        }
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    public static func formatBinaryDump(data: Data, width: Int = 80) -> String {
        let bytes = Array(data)
        guard !bytes.isEmpty else { return "" }
        var lines: [String] = []
        lines.reserveCapacity((bytes.count + width - 1) / width)

        var idx = 0
        while idx < bytes.count {
            let end = min(bytes.count, idx + width)
            var row = ""
            row.reserveCapacity(width)
            for b in bytes[idx..<end] {
                if b >= 32 && b < 127 {
                    row.append(Character(UnicodeScalar(b)))
                } else {
                    row.append(".")
                }
            }
            lines.append(row)
            idx = end
        }
        return lines.joined(separator: "\n")
    }

    public static func formatHexDumpRows(data: Data, maxRows: Int = 4096) -> [HexDumpRow] {
        let bytes = Array(data)
        guard !bytes.isEmpty else { return [] }
        let rowCount = min(maxRows, (bytes.count + 15) / 16)
        var rows: [HexDumpRow] = []
        rows.reserveCapacity(rowCount)

        for r in 0..<rowCount {
            let offset = r * 16
            let end = min(bytes.count, offset + 16)
            var hexLeft: [String] = []
            var hexRight: [String] = []
            var ascii = ""

            for i in 0..<16 {
                let pos = offset + i
                if pos < end {
                    let b = bytes[pos]
                    let h = String(format: "%02X", b)
                    if i < 8 { hexLeft.append(h) } else { hexRight.append(h) }
                    if b >= 32 && b < 127 {
                        ascii.append(Character(UnicodeScalar(b)))
                    } else {
                        ascii.append(".")
                    }
                } else {
                    if i < 8 { hexLeft.append("  ") } else { hexRight.append("  ") }
                    ascii.append(" ")
                }
            }

            let hexCombined = hexLeft.joined(separator: " ") + " | " + hexRight.joined(separator: " ")
            rows.append(
                HexDumpRow(
                    id: r,
                    offsetHex: String(format: "%08X", offset),
                    hexColumns: hexCombined,
                    asciiColumns: ascii
                )
            )
        }
        return rows
    }

    public static func formatHexDumpText(data: Data, maxRows: Int = 4096) -> String {
        formatHexDumpRows(data: data, maxRows: maxRows)
            .map { "\($0.offsetHex): \($0.hexColumns)  \($0.asciiColumns)" }
            .joined(separator: "\n")
    }
}

// MARK: - Disk Space Analyzer Engine

public struct DiskSpaceEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let fullPath: String
    public let isDirectory: Bool
    public let sizeBytes: Int64
    public let fileCount: Int
    public let percentageOfParent: Double
}

public enum DiskSpaceAnalyzerEngine {
    public static func analyzeDirectory(at path: String) throws -> (totalBytes: Int64, entries: [DiskSpaceEntry]) {
        let items = try FileSystemEngine.listDirectory(at: path, showHidden: true, includeParentEntry: false)
        var rawResults: [(FileItem, Int64, Int)] = []
        var grandTotal: Int64 = 0

        for item in items {
            if item.isDirectory && !item.isSymlink {
                let (dirSize, count) = calculateDirSizeAndCount(at: item.fullPath)
                rawResults.append((item, dirSize, count))
                grandTotal += dirSize
            } else {
                rawResults.append((item, item.size, 1))
                grandTotal += item.size
            }
        }

        let sorted = rawResults.sorted { $0.1 > $1.1 }
        let denom = max(1.0, Double(grandTotal))
        let entries = sorted.map { (item, bytes, count) in
            DiskSpaceEntry(
                id: item.fullPath,
                name: item.name,
                fullPath: item.fullPath,
                isDirectory: item.isDirectory,
                sizeBytes: bytes,
                fileCount: count,
                percentageOfParent: (Double(bytes) / denom) * 100.0
            )
        }

        return (grandTotal, entries)
    }

    private static func calculateDirSizeAndCount(at path: String) -> (Int64, Int) {
        guard let cStr = strdup(path) else { return (0, 0) }
        defer { free(cStr) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cStr, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return (0, 0) }
        defer { fts_close(fts) }

        var total: Int64 = 0
        var count = 0
        while let entry = fts_read(fts) {
            if Int32(entry.pointee.fts_info) == FTS_F, let st = entry.pointee.fts_statp {
                total += Int64(st.pointee.st_size)
                count += 1
            }
        }
        return (total, count)
    }
}
