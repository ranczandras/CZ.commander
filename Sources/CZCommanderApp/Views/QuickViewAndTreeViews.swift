import SwiftUI
import AppKit
import PDFKit
import CZCommanderCore

public struct QuickViewPaneView: View {
    @ObservedObject var viewModel: CommanderViewModel
    @State private var previewMode: ListerMode = .text

    private var palette: CommanderThemePalette { viewModel.themePalette }
    private var focusedItem: FileItem? { viewModel.activePanel.focusedItem }

    public init(viewModel: CommanderViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "eye.fill")
                    .foregroundColor(palette.activeHeaderText.swiftUIColor)
                Text("Quick View (Cmd+Y)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(palette.activeHeaderText.swiftUIColor)
                Spacer()
                SquarePicker("", selection: $previewMode, options: ListerMode.allCases.map { m in (value: m, title: m.displayName) }, kind: .segmented)
                .frame(width: 280)

                Button {
                    viewModel.isQuickViewActive = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(palette.activeHeaderText.swiftUIColor)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(palette.activeHeaderBackground.swiftUIColor)

            if let item = focusedItem {
                quickContent(for: item)
            } else {
                Spacer()
                Text("No item focused")
                    .foregroundColor(palette.inactiveHeaderText.swiftUIColor)
                Spacer()
            }
        }
        .background(palette.panelBackground.swiftUIColor)
        .overlay(
            Rectangle()
                .stroke(palette.dividerColor.swiftUIColor, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func quickContent(for item: FileItem) -> some View {
        if item.isParentDirectoryEntry {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "folder.fill")
                    .font(.system(size: 40))
                    .foregroundColor(palette.directoryText.swiftUIColor)
                Text(item.fullPath)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(palette.regularFileText.swiftUIColor)
                Spacer()
            }
        } else if item.isDirectory {
            directoryQuickSummary(for: item)
        } else if item.category == .image && previewMode != .hex && previewMode != .binary,
                  let nsImg = NSImage(contentsOfFile: item.fullPath) {
            VStack(spacing: 8) {
                Image(nsImage: nsImg)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
                Text("\(item.name) — \(Int(nsImg.size.width)) × \(Int(nsImg.size.height)) px — \(item.formattedSize(format: .dynamicKMGT))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(palette.regularFileText.swiftUIColor)
                    .padding(.bottom, 8)
            }
        } else {
            fileDataQuickPreview(for: item)
        }
    }

    private func directoryQuickSummary(for item: FileItem) -> some View {
        let subItems = (try? FileSystemEngine.listDirectory(at: item.fullPath, showHidden: true, includeParentEntry: false)) ?? []
        let dirCount = subItems.filter { $0.isDirectory }.count
        let fileCount = subItems.filter { !$0.isDirectory }.count
        let directBytes = subItems.reduce(Int64(0)) { $0 + $1.size }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 32))
                    .foregroundColor(palette.directoryText.swiftUIColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundColor(palette.directoryText.swiftUIColor)
                    Text(item.fullPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(palette.inactiveHeaderText.swiftUIColor)
                }
            }
            Divider()
            Text("Subdirectories: \(dirCount)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(palette.regularFileText.swiftUIColor)
            Text("Direct files: \(fileCount)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(palette.regularFileText.swiftUIColor)
            Text("Direct files size: \(FileItem.formatByteCount(directBytes, format: .dynamicKMGT))")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(palette.regularFileText.swiftUIColor)
            Text("Permissions: \(item.permissionsString) (\(item.octalPermissionsString))")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(palette.regularFileText.swiftUIColor)
            Spacer()
        }
        .padding(16)
    }

    private func fileDataQuickPreview(for item: FileItem) -> some View {
        let loaded = (try? ListerEngine.loadFilePreviewData(atPath: item.fullPath, maxBytes: 128 * 1024)) ?? (Data(), 0)
        let data = loaded.0
        let displayStr: String = {
            switch previewMode {
            case .hex:
                return ListerEngine.formatHexDumpText(data: data, maxRows: 512)
            case .binary:
                return ListerEngine.formatBinaryDump(data: data, width: 72)
            default:
                return ListerEngine.decodeText(data: data, encoding: .utf8)
            }
        }()

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(item.name) (\(item.formattedSize(format: .dynamicKMGT)))")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(palette.directoryText.swiftUIColor)
                Spacer()
                Text(item.permissionsString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(palette.inactiveHeaderText.swiftUIColor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(palette.toolbarBackground.swiftUIColor)

            ScrollView {
                Text(displayStr)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(palette.regularFileText.swiftUIColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - Separate Directory Tree Sidebar (Cmd+F8)

public struct DirectoryTreeSidebarView: View {
    @ObservedObject var viewModel: CommanderViewModel
    @State private var expandedPaths: Set<String> = ["/", "/Volumes"]

    private var palette: CommanderThemePalette { viewModel.themePalette }

    public init(viewModel: CommanderViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "sidebar.left")
                    .foregroundColor(palette.activeHeaderText.swiftUIColor)
                Text("Directory Tree (Cmd+F8)")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundColor(palette.activeHeaderText.swiftUIColor)
                Spacer()
                Button {
                    viewModel.showDirectoryTreeSidebar = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(palette.activeHeaderText.swiftUIColor)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(palette.activeHeaderBackground.swiftUIColor)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(viewModel.mountedVolumes) { vol in
                        treeNodeView(title: vol.name, path: vol.path, depth: 0)
                    }
                    Divider().padding(.vertical, 4)
                    let activeParent = (viewModel.activePanel.currentPath as NSString).deletingLastPathComponent
                    if activeParent != "/" && !activeParent.isEmpty {
                        treeNodeView(
                            title: (activeParent as NSString).lastPathComponent,
                            path: activeParent,
                            depth: 0
                        )
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 220)
        .background(palette.panelBackground.swiftUIColor)
        .overlay(
            Rectangle()
                .fill(palette.dividerColor.swiftUIColor)
                .frame(width: 1),
            alignment: .trailing
        )
    }

    private func treeNodeView(title: String, path: String, depth: Int) -> AnyView {
        let isExpanded = expandedPaths.contains(path)
        let isCurrent = viewModel.activePanel.currentPath == path
        let subdirs: [FileItem] = isExpanded
            ? ((try? FileSystemEngine.listDirectory(at: path, showHidden: false, includeParentEntry: false))?.filter { $0.isDirectory } ?? [])
            : []

        return AnyView(
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Button {
                        if isExpanded {
                            expandedPaths.remove(path)
                        } else {
                            expandedPaths.insert(path)
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(palette.inactiveHeaderText.swiftUIColor)
                            .frame(width: 12)
                    }
                    .buttonStyle(.plain)

                    Image(systemName: "folder.fill")
                        .font(.system(size: 11))
                        .foregroundColor(palette.directoryText.swiftUIColor)

                    Text(title)
                        .font(.system(size: 11.5, weight: isCurrent ? .bold : .regular, design: .monospaced))
                        .foregroundColor(isCurrent ? palette.cursorText.swiftUIColor : palette.regularFileText.swiftUIColor)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
                .padding(.leading, CGFloat(depth * 12))
                .padding(.vertical, 3)
                .padding(.horizontal, 4)
                .background(isCurrent ? palette.cursorBackground.swiftUIColor : Color.clear)
                
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.activePanel.navigateTo(path: path)
                    expandedPaths.insert(path)
                }

                if isExpanded && depth < 4 {
                    ForEach(subdirs.prefix(60)) { sub in
                        treeNodeView(title: sub.name, path: sub.fullPath, depth: depth + 1)
                    }
                }
            }
        )
    }
}
