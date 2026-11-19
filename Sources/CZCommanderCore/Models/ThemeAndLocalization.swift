import Foundation

public enum CommanderThemeID: String, CaseIterable, Codable, Sendable {
    case windowsDefault = "windowsDefault"
    case windowsClassicNavy = "windowsClassicNavy"
    case nortonClassicBlue = "nortonClassicBlue"
    case macDarkPro = "macDarkPro"
    case midnightMatrix = "midnightMatrix"
    case solarizedDark = "solarizedDark"

    public var displayName: String {
        switch self {
        case .windowsDefault: return "Windows Classic (Default)"
        case .windowsClassicNavy: return "Windows Classic (Navy cursor)"
        case .nortonClassicBlue: return "Norton Commander Classic Blue"
        case .macDarkPro: return "macOS Dark Pro"
        case .midnightMatrix: return "Midnight Matrix"
        case .solarizedDark: return "Solarized Commander"
        }
    }
}

public struct RGBAColor: Codable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1.0) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static func hex(_ hexValue: UInt32, alpha: Double = 1.0) -> RGBAColor {
        let r = Double((hexValue >> 16) & 0xFF) / 255.0
        let g = Double((hexValue >> 8) & 0xFF) / 255.0
        let b = Double(hexValue & 0xFF) / 255.0
        return RGBAColor(r, g, b, alpha)
    }
}

public struct CommanderThemePalette: Codable, Hashable, Sendable {
    public let id: CommanderThemeID
    public let isLightTheme: Bool
    public let useUniformBlackFileText: Bool
    public let panelBackground: RGBAColor
    public let panelAlternateRow: RGBAColor
    public let activeHeaderBackground: RGBAColor
    public let inactiveHeaderBackground: RGBAColor
    public let activeHeaderText: RGBAColor
    public let inactiveHeaderText: RGBAColor
    public let cursorBackground: RGBAColor
    public let cursorBorder: RGBAColor
    public let cursorText: RGBAColor
    public let selectedItemText: RGBAColor
    public let selectedRowTint: RGBAColor
    public let regularFileText: RGBAColor
    public let directoryText: RGBAColor
    public let archiveText: RGBAColor
    public let executableText: RGBAColor
    public let symlinkText: RGBAColor
    public let mediaText: RGBAColor
    public let sourceCodeText: RGBAColor
    public let hiddenText: RGBAColor
    public let toolbarBackground: RGBAColor
    public let statusBarBackground: RGBAColor
    public let dividerColor: RGBAColor

    public static func palette(for id: CommanderThemeID) -> CommanderThemePalette {
        switch id {
        case .windowsDefault:
            // Exact out-of-the-box Windows Total Commander default theme:
            // Pure white (#FFFFFF) file list, pure black (#000000) text, bright red (#FF0000) marked items,
            // classic Windows grey (#F0F0F0) toolbars/headers/buttons, classic blue (#004E98) active path bar,
            // grey (#808080) inactive path bar, light blue (#CCE8FF) cursor with #0054E3 border.
            return CommanderThemePalette(
                id: .windowsDefault,
                isLightTheme: true,
                useUniformBlackFileText: true,
                panelBackground: .hex(0xFFFFFF),
                panelAlternateRow: .hex(0xFFFFFF),
                activeHeaderBackground: .hex(0x004E98),
                inactiveHeaderBackground: .hex(0x808080),
                activeHeaderText: .hex(0xFFFFFF),
                inactiveHeaderText: .hex(0xF0F0F0),
                cursorBackground: .hex(0xCCE8FF),
                cursorBorder: .hex(0x0054E3),
                cursorText: .hex(0x000000),
                selectedItemText: .hex(0xFF0000),
                selectedRowTint: .hex(0xFFFFFF),
                regularFileText: .hex(0x000000),
                directoryText: .hex(0x000000),
                archiveText: .hex(0x000000),
                executableText: .hex(0x000000),
                symlinkText: .hex(0x000000),
                mediaText: .hex(0x000000),
                sourceCodeText: .hex(0x000000),
                hiddenText: .hex(0x555555),
                toolbarBackground: .hex(0xF0F0F0),
                statusBarBackground: .hex(0xE4E4E4),
                dividerColor: .hex(0xA0A0A0)
            )

        case .windowsClassicNavy:
            // Classic Windows 95/XP/7 Total Commander with solid Navy Blue (#000080) inverted cursor bar
            return CommanderThemePalette(
                id: .windowsClassicNavy,
                isLightTheme: true,
                useUniformBlackFileText: true,
                panelBackground: .hex(0xFFFFFF),
                panelAlternateRow: .hex(0xFFFFFF),
                activeHeaderBackground: .hex(0x000080),
                inactiveHeaderBackground: .hex(0x808080),
                activeHeaderText: .hex(0xFFFFFF),
                inactiveHeaderText: .hex(0xE0E0E0),
                cursorBackground: .hex(0x000080),
                cursorBorder: .hex(0x000000),
                cursorText: .hex(0xFFFFFF),
                selectedItemText: .hex(0xFF0000),
                selectedRowTint: .hex(0xFFFFFF),
                regularFileText: .hex(0x000000),
                directoryText: .hex(0x000000),
                archiveText: .hex(0x000000),
                executableText: .hex(0x000000),
                symlinkText: .hex(0x000000),
                mediaText: .hex(0x000000),
                sourceCodeText: .hex(0x000000),
                hiddenText: .hex(0x555555),
                toolbarBackground: .hex(0xD4D0C8),
                statusBarBackground: .hex(0xD4D0C8),
                dividerColor: .hex(0x808080)
            )

        case .nortonClassicBlue:
            return CommanderThemePalette(
                id: .nortonClassicBlue,
                isLightTheme: false,
                useUniformBlackFileText: false,
                panelBackground: .hex(0x000080),
                panelAlternateRow: .hex(0x000070),
                activeHeaderBackground: .hex(0x00AAAA),
                inactiveHeaderBackground: .hex(0x000050),
                activeHeaderText: .hex(0x000000),
                inactiveHeaderText: .hex(0xAAAAAA),
                cursorBackground: .hex(0x00AAAA),
                cursorBorder: .hex(0xFFFF55),
                cursorText: .hex(0x000000),
                selectedItemText: .hex(0xFFFF55),
                selectedRowTint: .hex(0x003399, alpha: 0.7),
                regularFileText: .hex(0x55FFFF),
                directoryText: .hex(0xFFFFFF),
                archiveText: .hex(0xFF55FF),
                executableText: .hex(0x55FF55),
                symlinkText: .hex(0xAAFFFF),
                mediaText: .hex(0xFFAA55),
                sourceCodeText: .hex(0x55FFAA),
                hiddenText: .hex(0x8888CC),
                toolbarBackground: .hex(0x005555),
                statusBarBackground: .hex(0x000055),
                dividerColor: .hex(0x55FFFF)
            )

        case .macDarkPro:
            return CommanderThemePalette(
                id: .macDarkPro,
                isLightTheme: false,
                useUniformBlackFileText: false,
                panelBackground: .hex(0x16181D),
                panelAlternateRow: .hex(0x1C1F26),
                activeHeaderBackground: .hex(0x1F5692),
                inactiveHeaderBackground: .hex(0x252830),
                activeHeaderText: .hex(0xFFFFFF),
                inactiveHeaderText: .hex(0x8C93A4),
                cursorBackground: .hex(0x285999, alpha: 0.85),
                cursorBorder: .hex(0x5CA3FF),
                cursorText: .hex(0xFFFFFF),
                selectedItemText: .hex(0xFF5555),
                selectedRowTint: .hex(0x4D1E24, alpha: 0.55),
                regularFileText: .hex(0xE6E9F0),
                directoryText: .hex(0xFFD166),
                archiveText: .hex(0xDA77F2),
                executableText: .hex(0x51CF66),
                symlinkText: .hex(0x4DABF7),
                mediaText: .hex(0xFF922B),
                sourceCodeText: .hex(0x63E6BE),
                hiddenText: .hex(0x6C757D),
                toolbarBackground: .hex(0x1E2128),
                statusBarBackground: .hex(0x121418),
                dividerColor: .hex(0x303642)
            )

        case .midnightMatrix:
            return CommanderThemePalette(
                id: .midnightMatrix,
                isLightTheme: false,
                useUniformBlackFileText: false,
                panelBackground: .hex(0x0A0E0C),
                panelAlternateRow: .hex(0x0F1612),
                activeHeaderBackground: .hex(0x134E2E),
                inactiveHeaderBackground: .hex(0x141C17),
                activeHeaderText: .hex(0x8CE99A),
                inactiveHeaderText: .hex(0x52796F),
                cursorBackground: .hex(0x1B4332),
                cursorBorder: .hex(0x40C057),
                cursorText: .hex(0xFFFFFF),
                selectedItemText: .hex(0xFCC419),
                selectedRowTint: .hex(0x2B3A1A, alpha: 0.6),
                regularFileText: .hex(0x96F2D7),
                directoryText: .hex(0x69DB7C),
                archiveText: .hex(0xE599F7),
                executableText: .hex(0xA9E34B),
                symlinkText: .hex(0x3BC9DB),
                mediaText: .hex(0xFFA94D),
                sourceCodeText: .hex(0x63E6BE),
                hiddenText: .hex(0x495057),
                toolbarBackground: .hex(0x0D1410),
                statusBarBackground: .hex(0x080B09),
                dividerColor: .hex(0x23382C)
            )

        case .solarizedDark:
            return CommanderThemePalette(
                id: .solarizedDark,
                isLightTheme: false,
                useUniformBlackFileText: false,
                panelBackground: .hex(0x002B36),
                panelAlternateRow: .hex(0x073642),
                activeHeaderBackground: .hex(0x268BD2),
                inactiveHeaderBackground: .hex(0x073642),
                activeHeaderText: .hex(0xFDF6E3),
                inactiveHeaderText: .hex(0x839496),
                cursorBackground: .hex(0x0B4F6C),
                cursorBorder: .hex(0x2AA198),
                cursorText: .hex(0xFDF6E3),
                selectedItemText: .hex(0xCB4B16),
                selectedRowTint: .hex(0x3C2318, alpha: 0.6),
                regularFileText: .hex(0x93A1A1),
                directoryText: .hex(0xB58900),
                archiveText: .hex(0xD33682),
                executableText: .hex(0x859900),
                symlinkText: .hex(0x2AA198),
                mediaText: .hex(0xCB4B16),
                sourceCodeText: .hex(0x268BD2),
                hiddenText: .hex(0x586E75),
                toolbarBackground: .hex(0x073642),
                statusBarBackground: .hex(0x00212B),
                dividerColor: .hex(0x586E75)
            )
        }
    }
}

public enum L10n {
    public static func statusSummary(
        selectedBytes: Int64,
        totalBytes: Int64,
        selectedFiles: Int,
        totalFiles: Int,
        selectedDirs: Int,
        totalDirs: Int,
        format: FileSizeDisplayFormat
    ) -> String {
        let selSize = FileItem.formatByteCount(selectedBytes, format: format)
        let totSize = FileItem.formatByteCount(totalBytes, format: format)
        return "\(selSize) / \(totSize) in \(selectedFiles) / \(totalFiles) file(s), \(selectedDirs) / \(totalDirs) dir(s)"
    }
}
