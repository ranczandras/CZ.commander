import Foundation

/// Semantic version helpers used by the GitHub update check.
public enum AppVersion {
    /// "v1.2.3" / "1.2" / "1.2.3-beta" -> [1, 2, 3]
    public static func components(_ version: String) -> [Int] {
        var v = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.hasPrefix("v") || v.hasPrefix("V") { v.removeFirst() }
        let core = v.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? v
        return core.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
    }

    /// True when `candidate` is a higher version than `current`.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate), b = components(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
