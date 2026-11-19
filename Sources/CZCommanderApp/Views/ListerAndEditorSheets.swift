import SwiftUI
import AppKit
import PDFKit
import CZCommanderCore

public struct ListerWindowSheetView: View {
    @ObservedObject var viewModel: CommanderViewModel
    public let filePath: String
    @State private var mode: ListerMode
    @State private var encoding: TextEncodingOption = .utf8
    @State private var wrapLines: Bool = true
    @State private var showLineNumbers: Bool = true
    @State private var searchQuery: String = ""
    @State private var caseSensitiveSearch: Bool = false
    @State private var hexSearch: Bool = false
    @State private var imageZoom: Double = 1.0
    @State private var loadedData: Data = Data()
    @State private var totalFileBytes: Int64 = 0
    private func dismiss() { CommanderDialog.close(viewModel) }

    private var palette: CommanderThemePalette { viewModel.themePalette }

    public init(viewModel: CommanderViewModel, filePath: String, initialMode: ListerMode = .text) {
        self.viewModel = viewModel
        self.filePath = filePath
        self._mode = State(initialValue: initialMode)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top Lister Toolbar
            HStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 15, weight: .bold))
                Text("Lister (F3) — \((filePath as NSString).lastPathComponent)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .lineLimit(1)

                Spacer()

                SquarePicker("", selection: $mode, options: ListerMode.allCases.map { m in (value: m, title: m.displayName) }, kind: .segmented)
                .frame(width: 380)

                if mode == .text {
                    SquarePicker("", selection: $encoding, options: TextEncodingOption.allCases.map { enc in (value: enc, title: enc.rawValue) })
                    .frame(width: 150)

                    Toggle("Wrap", isOn: $wrapLines)
                        .toggleStyle(.checkbox)
                    Toggle("Lines", isOn: $showLineNumbers)
                        .toggleStyle(.checkbox)
                }

                Button("Close (Esc)") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(10)
            .background(palette.toolbarBackground.swiftUIColor)

            // Search Bar (F7 / F3)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                TextField("Search in file (F7)...", text: $searchQuery)
                    .textFieldStyle(SquareTextFieldStyle())
                    .font(.system(size: 12, design: .monospaced))
                Toggle("Case sensitive", isOn: $caseSensitiveSearch)
                    .toggleStyle(.checkbox)
                Toggle("Hex", isOn: $hexSearch)
                    .toggleStyle(.checkbox)

                if !searchQuery.isEmpty {
                    Text(matchSummaryText)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.orange)
                }

                Spacer()
                Text("\(FileItem.formatByteCount(totalFileBytes, format: .dynamicKMGT)) (\(FileItem.formatWithThousandsSeparator(totalFileBytes)) B)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(palette.statusBarBackground.swiftUIColor)

            Divider()

            // Main Viewer Content
            Group {
                switch mode {
                case .text:
                    textModeView
                case .binary:
                    binaryModeView
                case .hex:
                    hexModeView
                case .multimedia:
                    multimediaModeView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.panelBackground.swiftUIColor)
        }
        .frame(minWidth: 880, minHeight: 600)
        .onAppear {
            if let res = try? ListerEngine.loadFilePreviewData(atPath: filePath) {
                loadedData = res.0
                totalFileBytes = res.1
            }
            let ext = (filePath as NSString).pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "pdf", "svg", "icns"].contains(ext) && mode == .text {
                mode = .multimedia
            }
        }
    }

    private var decodedText: String {
        ListerEngine.decodeText(data: loadedData, encoding: encoding)
    }

    private var matchSummaryText: String {
        guard !searchQuery.isEmpty else { return "" }
        if hexSearch {
            return mode == .hex ? "Hex filter active" : ""
        }
        let text = decodedText
        let opts: String.CompareOptions = caseSensitiveSearch ? [] : [.caseInsensitive]
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: searchQuery, options: opts, range: searchRange) {
            count += 1
            searchRange = found.upperBound..<text.endIndex
        }
        return "\(count) match(es)"
    }

    private var textModeView: some View {
        let lines = decodedText.components(separatedBy: .newlines)
        let filteredLines: [(Int, String)] = {
            if searchQuery.isEmpty || hexSearch {
                return lines.enumerated().map { ($0.offset + 1, $0.element) }
            }
            let opts: String.CompareOptions = caseSensitiveSearch ? [] : [.caseInsensitive]
            return lines.enumerated().compactMap { (idx, line) in
                line.range(of: searchQuery, options: opts) != nil ? (idx + 1, line) : nil
            }
        }()

        return ScrollView([wrapLines ? .vertical : .horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(filteredLines, id: \.0) { (lineNum, lineText) in
                    HStack(alignment: .top, spacing: 8) {
                        if showLineNumbers {
                            Text(String(format: "%5d", lineNum))
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundColor(palette.inactiveHeaderText.swiftUIColor)
                                .frame(width: 48, alignment: .trailing)
                        }
                        Text(lineText.isEmpty ? " " : lineText)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(palette.regularFileText.swiftUIColor)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 8)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var binaryModeView: some View {
        let dump = ListerEngine.formatBinaryDump(data: loadedData, width: 80)
        return ScrollView {
            Text(dump)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(palette.regularFileText.swiftUIColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .textSelection(.enabled)
        }
    }

    private var hexModeView: some View {
        let rows = ListerEngine.formatHexDumpRows(data: loadedData, maxRows: 8192)
        let filteredRows: [HexDumpRow] = {
            guard !searchQuery.isEmpty else { return rows }
            return rows.filter {
                $0.hexColumns.localizedCaseInsensitiveContains(searchQuery)
                    || $0.asciiColumns.localizedCaseInsensitiveContains(searchQuery)
            }
        }()

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(filteredRows) { row in
                    HStack(spacing: 12) {
                        Text(row.offsetHex)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(palette.directoryText.swiftUIColor)
                        Text(row.hexColumns)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(palette.regularFileText.swiftUIColor)
                        Text(row.asciiColumns)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(palette.executableText.swiftUIColor)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 1)
                }
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var multimediaModeView: some View {
        let ext = (filePath as NSString).pathExtension.lowercased()
        if ext == "pdf", let pdfDoc = PDFDocument(url: URL(fileURLWithPath: filePath)) {
            PDFKitRepresentedView(document: pdfDoc)
        } else if let nsImage = NSImage(contentsOfFile: filePath) {
            VStack(spacing: 8) {
                HStack {
                    Text("Zoom:")
                    Slider(value: $imageZoom, in: 0.2...4.0)
                        .frame(width: 160)
                    Text("\(Int(imageZoom * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                    Button("100%") { imageZoom = 1.0 }
                    Spacer()
                    Text("\(Int(nsImage.size.width)) × \(Int(nsImage.size.height)) px")
                        .font(.system(size: 11, design: .monospaced))
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)

                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(
                            width: max(120, nsImage.size.width * imageZoom),
                            height: max(120, nsImage.size.height * imageZoom)
                        )
                        .padding(16)
                }
            }
        } else {
            textModeView
        }
    }
}

struct PDFKitRepresentedView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = document
        pdfView.autoScales = true
        return pdfView
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        nsView.document = document
    }
}

// MARK: - F4 Internal Editor Sheet (and Shift+F4 New File)

public struct InternalEditorSheetView: View {
    @ObservedObject var viewModel: CommanderViewModel
    @State private var targetFilePath: String
    public let isNewFile: Bool
    @State private var textContent: String = ""
    @State private var encoding: TextEncodingOption = .utf8
    @State private var findText: String = ""
    @State private var replaceText: String = ""
    @State private var statusMessage: String = ""
    private func dismiss() { CommanderDialog.close(viewModel) }


    public init(viewModel: CommanderViewModel, filePath: String, isNewFile: Bool) {
        self.viewModel = viewModel
        self._targetFilePath = State(initialValue: filePath)
        self.isNewFile = isNewFile
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 15, weight: .bold))
                Text("Internal Editor (F4)")
                    .font(.system(size: 13, weight: .bold))

                TextField("File path", text: $targetFilePath)
                    .textFieldStyle(SquareTextFieldStyle())
                    .font(.system(size: 12, design: .monospaced))

                SquarePicker("", selection: $encoding, options: TextEncodingOption.allCases.map { enc in (value: enc, title: enc.rawValue) })
                .frame(width: 140)

                Button("External App") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: targetFilePath))
                }

                Button("Save (Cmd+S)") {
                    saveFile(closeAfter: false)
                }
                .keyboardShortcut("s", modifiers: [.command])

                Button("Save & Close") {
                    saveFile(closeAfter: true)
                }
                .keyboardShortcut(.defaultAction)

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(10)

            // Find & Replace Bar
            HStack(spacing: 8) {
                Text("Find:")
                    .font(.system(size: 11))
                TextField("Find...", text: $findText)
                    .textFieldStyle(SquareTextFieldStyle())
                    .frame(width: 180)
                Text("Replace:")
                    .font(.system(size: 11))
                TextField("Replace with...", text: $replaceText)
                    .textFieldStyle(SquareTextFieldStyle())
                    .frame(width: 180)

                Button("Replace All") {
                    guard !findText.isEmpty else { return }
                    textContent = textContent.replacingOccurrences(of: findText, with: replaceText)
                    statusMessage = "Replaced occurrences"
                }

                Spacer()
                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.green)
                }
                Text("\(textContent.components(separatedBy: .newlines).count) lines | \(textContent.utf8.count) B")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            Divider()

            TextEditor(text: $textContent)
                .font(.system(size: 13, design: .monospaced))
                .padding(6)
        }
        .frame(minWidth: 860, minHeight: 580)
        .onAppear {
            if !isNewFile, FileManager.default.fileExists(atPath: targetFilePath) {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: targetFilePath)) {
                    textContent = ListerEngine.decodeText(data: data, encoding: encoding)
                }
            }
        }
    }

    private func saveFile(closeAfter: Bool) {
        do {
            try textContent.write(toFile: targetFilePath, atomically: true, encoding: encoding.stringEncoding)
            statusMessage = "Saved!"
            viewModel.leftPanel.reload()
            viewModel.rightPanel.reload()
            if closeAfter {
                dismiss()
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}
