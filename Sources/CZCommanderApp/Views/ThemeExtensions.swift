import SwiftUI
import AppKit
import CZCommanderCore

extension RGBAColor {
    public var swiftUIColor: Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

extension CommanderThemePalette {
    public func textColor(for item: FileItem, isSelected: Bool, isFocused: Bool) -> Color {
        if isSelected {
            if isFocused && id == .windowsClassicNavy {
                return Color(.sRGB, red: 1.0, green: 1.0, blue: 0.2, opacity: 1.0)
            }
            return selectedItemText.swiftUIColor
        }
        if isFocused {
            return cursorText.swiftUIColor
        }
        if useUniformBlackFileText {
            return item.isHidden ? hiddenText.swiftUIColor : regularFileText.swiftUIColor
        }
        switch item.category {
        case .parentDirectory, .directory:
            return directoryText.swiftUIColor
        case .symlink:
            return symlinkText.swiftUIColor
        case .executable:
            return executableText.swiftUIColor
        case .archive:
            return archiveText.swiftUIColor
        case .image, .audioVideo:
            return mediaText.swiftUIColor
        case .sourceCode:
            return sourceCodeText.swiftUIColor
        case .hidden:
            return hiddenText.swiftUIColor
        case .document, .regular:
            return regularFileText.swiftUIColor
        }
    }

    public func iconColor(for item: FileItem, isSelected: Bool, isFocused: Bool) -> Color {
        if !useUniformBlackFileText {
            return textColor(for: item, isSelected: isSelected, isFocused: isFocused)
        }
        if item.isParentDirectoryEntry {
            return (isFocused && id == .windowsClassicNavy) ? .white : Color(.sRGB, red: 0.15, green: 0.15, blue: 0.15, opacity: 1.0)
        }
        if item.isDirectory {
            // Classic Windows Golden-Yellow Folder Icon (#E8A800)
            return Color(.sRGB, red: 0.91, green: 0.66, blue: 0.0, opacity: 1.0)
        }
        switch item.category {
        case .archive:
            return Color(.sRGB, red: 0.72, green: 0.42, blue: 0.08, opacity: 1.0)
        case .executable:
            return Color(.sRGB, red: 0.0, green: 0.42, blue: 0.80, opacity: 1.0)
        case .image, .audioVideo:
            return Color(.sRGB, red: 0.12, green: 0.55, blue: 0.35, opacity: 1.0)
        default:
            return (isFocused && id == .windowsClassicNavy) ? .white : Color(.sRGB, red: 0.35, green: 0.40, blue: 0.46, opacity: 1.0)
        }
    }

    public func sfSymbol(for item: FileItem) -> String {
        if item.isParentDirectoryEntry {
            return "arrow.turn.left.up"
        }
        if item.isDirectory {
            return item.isSymlink ? "folder.fill.badge.person.crop" : "folder.fill"
        }
        if item.isSymlink {
            return "link"
        }
        switch item.category {
        case .archive:
            return "archivebox.fill"
        case .executable:
            return "app.fill"
        case .image:
            return "photo.fill"
        case .audioVideo:
            return "film.fill"
        case .sourceCode:
            return "doc.text.fill"
        case .document:
            return "doc.text.fill"
        case .hidden:
            return "doc"
        default:
            return "doc"
        }
    }
}

extension FinderTagColor {
    public var dotColor: Color {
        switch self {
        case .none: return .clear
        case .gray: return .gray
        case .green: return .green
        case .purple: return .purple
        case .blue: return .blue
        case .yellow: return .yellow
        case .red: return .red
        case .orange: return .orange
        }
    }
}

/// Square-cornered replacement for `.borderedProminent` (CZ.commander uses no rounded corners).
public struct SquareProminentButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Rectangle().fill(Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1.0)))
            .foregroundColor(.white)
            .contentShape(Rectangle())
    }
}

/// Toolbar label without the "(shortcut)" part: "Branch (Cmd+B)" -> "Branch".
func toolbarShortTitle(_ title: String) -> String {
    guard let idx = title.firstIndex(of: "(") else { return title }
    let trimmed = title[..<idx].trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? title : trimmed
}
