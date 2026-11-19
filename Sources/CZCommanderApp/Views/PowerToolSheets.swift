import SwiftUI
import CZCommanderCore

// MARK: - 1. Multi-Rename Tool Sheet (Cmd+M)

public struct MultiRenameToolSheetView: View {
    @ObservedObject var viewModel: CommanderViewModel
    @State private var currentItems: [FileItem]
    @State private var config = MultiRenameConfig()
    @State private var lastBatchRecord: MultiRenameBatchRecord? = nil
    @State private var statusMessage: String = ""
    private func dismiss() { CommanderDialog.close(viewModel) }


    public init(viewModel: CommanderViewModel, items: [FileItem]) {
        self.viewModel = viewModel
        self._currentItems = State(initialValue: items)
    }

    private var previewRows: [MultiRenamePreviewRow] {
        MultiRenameEngine.generatePreview(items: currentItems, config: config)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "pencil.and.list.clipboard")
                    .font(.system(size: 18, weight: .bold))
                Text("Multi-Rename Tool (Cmd+M)")
                    .font(.headline)
                Spacer()
                Menu("F2 Presets") {
                    ForEach(viewModel.multiRenamePresets) { preset in
                        Button(preset.name) {
                            config = preset.config
                        }
                    }
                    Divider()
                    Button("➕ Save Current as Preset") {
                        let title = "\(config.nameMask).\(config.extensionMask)"
                        viewModel.multiRenamePresets.append(MultiRenamePreset(name: title, config: config))
                        viewModel.saveCurrentConfiguration()
                    }
                }
                .frame(width: 180)

                Button("Reset") {
                    config = MultiRenameConfig()
                }
            }

            HStack(alignment: .top, spacing: 16) {
                // Left: Name & Extension Masks
                GroupBox(label: Text("Rename mask: file name & extension")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("File name:").font(.caption)
                                TextField("[N]", text: $config.nameMask)
                                    .textFieldStyle(SquareTextFieldStyle())
                                    .font(.system(size: 12, design: .monospaced))
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Extension:").font(.caption)
                                TextField("[E]", text: $config.extensionMask)
                                    .textFieldStyle(SquareTextFieldStyle())
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(width: 90)
                            }
                        }

                        HStack(spacing: 4) {
                            ForEach(["[N]", "[N1-5]", "[C]", "[YMD]", "[hms]", "[P]", "[G]"], id: \.self) { tok in
                                Button(tok) { config.nameMask += tok }
                                    .controlSize(.small)
                            }
                        }

                        SquarePicker("Upper/lowercase:", selection: $config.caseMode, options: MultiRenameCaseMode.allCases.map { m in (value: m, title: m.displayName) })
                    }
                    .padding(6)
                }

                // Middle: Search & Replace
                GroupBox(label: Text("Search & Replace")) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Search for:").frame(width: 75, alignment: .leading)
                            TextField("a|b|c or regex", text: $config.searchFor)
                                .textFieldStyle(SquareTextFieldStyle())
                                .font(.system(size: 12, design: .monospaced))
                        }
                        HStack {
                            Text("Replace with:").frame(width: 75, alignment: .leading)
                            TextField("x|y|z", text: $config.replaceWith)
                                .textFieldStyle(SquareTextFieldStyle())
                                .font(.system(size: 12, design: .monospaced))
                        }
                        HStack(spacing: 12) {
                            Toggle("a=A", isOn: $config.caseSensitiveSearch)
                            Toggle("1×", isOn: $config.replaceOnlyOnce)
                            Toggle("RegEx", isOn: $config.useRegex)
                            Toggle("[E]", isOn: $config.applySearchReplaceToExtension)
                        }
                        .font(.caption)
                    }
                    .padding(6)
                }

                // Right: Counter [C]
                GroupBox(label: Text("Define counter [C]")) {
                    VStack(alignment: .leading, spacing: 6) {
                        SquareStepper("Start at: \(config.counterStart)", value: $config.counterStart, in: 0...999999)
                        SquareStepper("Step by: \(config.counterStep)", value: $config.counterStep, in: 1...1000)
                        SquareStepper("Digits: \(config.counterDigits)", value: $config.counterDigits, in: 1...10)
                    }
                    .padding(6)
                }
            }

            // Live Preview Table
            VStack(spacing: 0) {
                HStack {
                    Text("Old Name")
                        .font(.system(size: 11, weight: .bold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("New Name (Live Preview)")
                        .font(.system(size: 11, weight: .bold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Size")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 90, alignment: .trailing)
                    Text("Status")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 130, alignment: .leading)
                        .padding(.leading, 10)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.15))

                List(previewRows) { row in
                    HStack {
                        Text(row.originalName)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.proposedName)
                            .font(.system(size: 12, weight: row.isChanged ? .bold : .regular, design: .monospaced))
                            .foregroundColor(row.hasConflict ? .red : (row.isChanged ? .green : .primary))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.item.formattedSize(format: .dynamicKMG))
                            .font(.system(size: 11.5, design: .monospaced))
                            .frame(width: 90, alignment: .trailing)
                        Text(row.hasConflict ? (row.conflictReason ?? "Conflict") : (row.isChanged ? "Ready" : "Unchanged"))
                            .font(.system(size: 11))
                            .foregroundColor(row.hasConflict ? .red : .secondary)
                            .frame(width: 130, alignment: .leading)
                            .padding(.leading, 10)
                    }
                }
                .frame(minHeight: 260)
            }

            HStack {
                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.green)
                }

                Spacer()

                Button("Undo Last Batch") {
                    guard let batch = lastBatchRecord else { return }
                    do {
                        try MultiRenameEngine.undoRename(batch: batch)
                        lastBatchRecord = nil
                        statusMessage = "Undo completed!"
                        viewModel.leftPanel.reload()
                        viewModel.rightPanel.reload()
                    } catch {
                        statusMessage = error.localizedDescription
                    }
                }
                .disabled(lastBatchRecord == nil)

                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Start!") {
                    do {
                        let rows = previewRows
                        let batch = try MultiRenameEngine.executeRename(previewRows: rows)
                        lastBatchRecord = batch
                        statusMessage = "Renamed \(batch.operations.count) file(s)!"
                        viewModel.leftPanel.reload()
                        viewModel.rightPanel.reload()
                        currentItems = viewModel.activePanel.actionableItems
                    } catch {
                        statusMessage = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(previewRows.contains(where: { $0.hasConflict }))
            }
        }
        .padding(18)
        .frame(minWidth: 920, minHeight: 580)
    }
}

// MARK: - 2. Find Files Sheet (Alt+F7)

public struct FindFilesSheetView: View {
    @ObservedObject var viewModel: CommanderViewModel
    @State private var query: FindFilesQuery
    @State private var results: [FileItem] = []
    @State private var duplicateGroups: [[FileItem]] = []
    @State private var selectedResultID: String? = nil
    @State private var statusText: String = ""
    private func dismiss() { CommanderDialog.close(viewModel) }


    @State private var selectedTab = 0
    @State private var isSearching = false

    public init(viewModel: CommanderViewModel, initialPath: String) {
        self.viewModel = viewModel
        self._query = State(initialValue: FindFilesQuery(searchForMask: "*", searchInPaths: [initialPath]))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass.circle.fill")
                    .font(.system(size: 18, weight: .bold))
                Text("Find Files (Alt+F7)")
                    .font(.headline)
                Spacer()
                Button(isSearching ? "Searching…" : "Start Search") {
                    runSearch()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSearching)
            }

            VStack(alignment: .leading, spacing: 0) {
                SquareTabBar(titles: ["General", "Advanced", "Duplicates"], selection: $selectedTab)
                Group {
                    switch selectedTab {
                    case 0:
                // Tab 1: General
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Search for:").frame(width: 140, alignment: .leading)
                        TextField("*.swift;*.md | *Test*", text: $query.searchForMask)
                            .textFieldStyle(SquareTextFieldStyle())
                            .font(.system(size: 12, design: .monospaced))
                        Toggle("RegEx", isOn: $query.useRegexForName)
                    }
                    HStack {
                        Text("Search in:").frame(width: 140, alignment: .leading)
                        TextField("Path", text: Binding(
                            get: { query.searchInPaths.joined(separator: ";") },
                            set: { query.searchInPaths = $0.split(separator: ";").map(String.init) }
                        ))
                        .textFieldStyle(SquareTextFieldStyle())
                        .font(.system(size: 12, design: .monospaced))
                    }
                    HStack(spacing: 18) {
                        Toggle("Search inside archives", isOn: $query.searchInsideArchives)
                        Toggle("Include hidden files", isOn: $query.includeHidden)
                    }
                    Divider()
                    HStack {
                        Text("Find text:").frame(width: 140, alignment: .leading)
                        TextField("Text or Hex bytes...", text: $query.findText)
                            .textFieldStyle(SquareTextFieldStyle())
                            .font(.system(size: 12, design: .monospaced))
                    }
                    HStack(spacing: 14) {
                        Toggle("Case sensitive", isOn: $query.textCaseSensitive)
                        Toggle("Whole words only", isOn: $query.textWholeWordsOnly)
                        Toggle("RegEx", isOn: $query.textUseRegex)
                        Toggle("Hex", isOn: $query.textHexMode)
                        Toggle("Find files NOT containing text", isOn: $query.invertTextMatch)
                    }
                }
                    case 1:

                // Tab 2: Advanced
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("File size:").frame(width: 120, alignment: .leading)
                        SquarePicker("", selection: $query.sizeComparator, options: SizeComparator.allCases.map { c in (value: c, title: c.rawValue) })
                        .frame(width: 90)
                        TextField("0", value: $query.sizeValue, format: .number)
                            .textFieldStyle(SquareTextFieldStyle())
                            .frame(width: 100)
                        SquarePicker("", selection: $query.sizeUnit, options: SizeUnit.allCases.map { u in (value: u, title: u.label) })
                        .frame(width: 90)
                    }
                    HStack(spacing: 16) {
                        Toggle("Directories only", isOn: $query.onlyDirectories)
                        Toggle("Files only", isOn: $query.onlyFiles)
                        Toggle("Executables only", isOn: $query.onlyExecutables)
                    }
                    HStack {
                        Toggle("Not older than:", isOn: $query.notOlderThanEnabled)
                        TextField("7", value: $query.notOlderThanValue, format: .number)
                            .textFieldStyle(SquareTextFieldStyle())
                            .frame(width: 60)
                        SquarePicker("", selection: $query.notOlderThanUnit, options: AgeUnit.allCases.map { u in (value: u, title: u.rawValue) })
                        .frame(width: 110)
                    }
                }
                    default:

                // Tab 3: Duplicate Files
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Find duplicate files", isOn: $query.findDuplicates)
                        .font(.headline)
                    HStack(spacing: 20) {
                        Toggle("Same name", isOn: $query.duplicatesSameName)
                        Toggle("Same size", isOn: $query.duplicatesSameSize)
                        Toggle("Same content (SHA-256)", isOn: $query.duplicatesSameContent)
                    }
                    .disabled(!query.findDuplicates)
                }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .overlay(Rectangle().stroke(Color(nsColor: .separatorColor), lineWidth: 0.8))
            }
            .frame(height: 185)

            // Search Results List
            List(results, selection: $selectedResultID) { item in
                HStack {
                    Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                        .foregroundColor(item.isDirectory ? .yellow : .blue)
                    Text(item.fullPath)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if !item.descriptionComment.isEmpty {
                        Text(item.descriptionComment)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(.purple)
                    }
                    Text(item.formattedSize(format: .dynamicKMG))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 85, alignment: .trailing)
                }
                .tag(item.id)
            }
            .frame(minHeight: 220)

            HStack {
                Text(statusText)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)

                Spacer()

                Button("View (F3)") {
                    if let selID = selectedResultID, let item = results.first(where: { $0.id == selID }) {
                        dismiss()
                        viewModel.activeSheet = .lister(filePath: item.fullPath, initialMode: .text)
                    }
                }
                .disabled(selectedResultID == nil)

                Button("Go to file") {
                    if let selID = selectedResultID, let item = results.first(where: { $0.id == selID }) {
                        let parent = (item.fullPath as NSString).deletingLastPathComponent
                        viewModel.activePanel.navigateTo(path: parent, selectingChildNamed: item.name)
                        dismiss()
                    }
                }
                .disabled(selectedResultID == nil)

                Button("Feed to Listbox") {
                    viewModel.activePanel.feedSearchResults(results, title: query.searchForMask)
                    dismiss()
                }
                .disabled(results.isEmpty)

                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(minWidth: 860, minHeight: 560)
    }

    /// Runs the search off the main thread so the window stays responsive (searching a whole
    /// home folder can take a while). Starts only on "Start Search", like Total Commander.
    private func runSearch() {
        guard !isSearching else { return }
        isSearching = true
        statusText = "Searching…"
        let q = query
        Task.detached(priority: .userInitiated) {
            let res = FindFilesEngine.search(query: q)
            await MainActor.run {
                results = res.matchedItems
                duplicateGroups = res.duplicateGroups
                selectedResultID = results.first?.id
                statusText = "Found \(results.count) item(s) (scanned \(res.scannedFilesCount) files, \(res.scannedDirectoriesCount) folders)"
                isSearching = false
            }
        }
    }
}

// MARK: - 3. Synchronize Directories Sheet

public struct SynchronizeDirectoriesSheetView: View {
    @ObservedObject var viewModel: CommanderViewModel
    @State private var leftPath: String
    @State private var rightPath: String
    @State private var options = SyncOptions()
    @State private var entries: [SyncComparisonEntry] = []

    @State private var showLR: Bool = true
    @State private var showEqual: Bool = true
    @State private var showUnequal: Bool = true
    @State private var showRL: Bool = true
    @State private var showDuplicates: Bool = true
    @State private var showSingles: Bool = true
    @State private var statusBanner: String = ""
    private func dismiss() { CommanderDialog.close(viewModel) }


    public init(viewModel: CommanderViewModel, leftPath: String, rightPath: String) {
        self.viewModel = viewModel
        self._leftPath = State(initialValue: leftPath)
        self._rightPath = State(initialValue: rightPath)
    }

    private var filteredEntries: [SyncComparisonEntry] {
        entries.filter { entry in
            if entry.isDuplicate && !showDuplicates { return false }
            if entry.isSingle && !showSingles { return false }
            switch entry.direction {
            case .copyLeftToRight: return showLR
            case .equal: return showEqual
            case .unequal: return showUnequal
            case .copyRightToLeft, .deleteRight: return showRL
            case .skip: return true
            }
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "arrow.left.arrow.right.square.fill")
                    .font(.system(size: 18, weight: .bold))
                Text("Synchronize Directories")
                    .font(.headline)
                Spacer()
                Button("Compare") {
                    runCompare()
                }
            }

            HStack(spacing: 12) {
                TextField("Left path", text: $leftPath)
                    .textFieldStyle(SquareTextFieldStyle())
                    .font(.system(size: 12, design: .monospaced))
                TextField("*.ext", text: $options.fileMask)
                    .textFieldStyle(SquareTextFieldStyle())
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 100)
                TextField("Right path", text: $rightPath)
                    .textFieldStyle(SquareTextFieldStyle())
                    .font(.system(size: 12, design: .monospaced))
            }

            HStack(spacing: 16) {
                Toggle("Subdirs", isOn: $options.includeSubdirs)
                Toggle("By content", isOn: $options.compareByContent)
                Toggle("Ignore date", isOn: $options.ignoreDate)
                Toggle("Asymmetric", isOn: $options.asymmetric)

                Spacer()

                // Directional Filter Toggles
                Toggle("[->]", isOn: $showLR).toggleStyle(SquareButtonToggleStyle())
                Toggle("[==]", isOn: $showEqual).toggleStyle(SquareButtonToggleStyle())
                Toggle("[!=]", isOn: $showUnequal).toggleStyle(SquareButtonToggleStyle())
                Toggle("[<-]", isOn: $showRL).toggleStyle(SquareButtonToggleStyle())
                Toggle("Duplicates", isOn: $showDuplicates).toggleStyle(SquareButtonToggleStyle())
                Toggle("Singles", isOn: $showSingles).toggleStyle(SquareButtonToggleStyle())
            }

            List {
                ForEach(filteredEntries) { entry in
                    HStack {
                        Text(entry.leftItem != nil ? entry.relativePath : "—")
                            .font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(entry.leftItem?.formattedSize(format: .dynamicKMG) ?? "")
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 80, alignment: .trailing)

                        Button {
                            cycleDirection(for: entry.id)
                        } label: {
                            Text(entry.direction.rawValue)
                                .font(.system(size: 12, weight: .heavy, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(directionColor(entry.direction).opacity(0.25))
                                .foregroundColor(directionColor(entry.direction))
                                
                        }
                        .buttonStyle(.plain)
                        .frame(width: 60)

                        Text(entry.rightItem?.formattedSize(format: .dynamicKMG) ?? "")
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 80, alignment: .trailing)
                        Text(entry.rightItem != nil ? entry.relativePath : "—")
                            .font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(minHeight: 280)

            HStack {
                Text(statusBanner)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.green)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Synchronize...") {
                    do {
                        let res = try DirectorySyncEngine.executeSync(entries: entries, leftRoot: leftPath, rightRoot: rightPath)
                        statusBanner = "Sync complete: -> \(res.copiedLeftToRight), <- \(res.copiedRightToLeft), deleted: \(res.deletedFromRight)"
                        runCompare()
                        viewModel.leftPanel.reload()
                        viewModel.rightPanel.reload()
                    } catch {
                        statusBanner = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(minWidth: 920, minHeight: 560)
        .onAppear {
            runCompare()
        }
    }

    private func runCompare() {
        entries = DirectorySyncEngine.compareDirectories(leftRoot: leftPath, rightRoot: rightPath, options: options)
        let lr = entries.filter { $0.direction == .copyLeftToRight }.count
        let rl = entries.filter { $0.direction == .copyRightToLeft }.count
        let eq = entries.filter { $0.direction == .equal }.count
        statusBanner = "Total: \(entries.count) | [->] \(lr) | [==] \(eq) | [<-] \(rl)"
    }

    private func cycleDirection(for entryID: String) {
        guard let idx = entries.firstIndex(where: { $0.id == entryID }) else { return }
        switch entries[idx].direction {
        case .copyLeftToRight: entries[idx].direction = .copyRightToLeft
        case .copyRightToLeft: entries[idx].direction = .skip
        case .skip: entries[idx].direction = .copyLeftToRight
        case .equal: entries[idx].direction = .copyLeftToRight
        case .unequal: entries[idx].direction = .copyLeftToRight
        case .deleteRight: entries[idx].direction = .skip
        }
    }

    private func directionColor(_ dir: SyncActionDirection) -> Color {
        switch dir {
        case .copyLeftToRight: return .green
        case .copyRightToLeft: return .blue
        case .equal: return .secondary
        case .unequal, .deleteRight: return .red
        case .skip: return .orange
        }
    }
}

// MARK: - 4. Compare By Content Sheet (Side-by-Side Diff)

public struct CompareByContentSheetView: View {
    @ObservedObject var viewModel: CommanderViewModel
    public let leftPath: String
    public let rightPath: String
    @State private var ignoreCase: Bool = false
    @State private var ignoreSpaces: Bool = false
    @State private var binaryMode: Bool = false
    @State private var report: ContentComparisonReport? = nil
    @State private var currentDiffCursor: Int = 0
    private func dismiss() { CommanderDialog.close(viewModel) }


    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: 18, weight: .bold))
                Text("Compare By Content")
                    .font(.headline)
                Spacer()
                Toggle("Ignore case", isOn: $ignoreCase)
                    .onChange(of: ignoreCase) { _, _ in recompute() }
                Toggle("Ignore spaces", isOn: $ignoreSpaces)
                    .onChange(of: ignoreSpaces) { _, _ in recompute() }
                Toggle("Binary mode", isOn: $binaryMode)
                    .onChange(of: binaryMode) { _, _ in recompute() }
            }

            HStack {
                Text("⬅️ \(leftPath)")
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("➡️ \(rightPath)")
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.12))

            if let rep = report {
                ScrollViewReader { proxy in
                    List(rep.rows) { row in
                        HStack(spacing: 8) {
                            Text(row.leftLineNumber.map { String(format: "%4d", $0) } ?? "    ")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text(row.leftText.isEmpty ? " " : row.leftText)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 1)
                                .background(diffRowColor(row.kind, isLeft: true))

                            Divider()

                            Text(row.rightLineNumber.map { String(format: "%4d", $0) } ?? "    ")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text(row.rightText.isEmpty ? " " : row.rightText)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 1)
                                .background(diffRowColor(row.kind, isLeft: false))
                        }
                        .id(row.id)
                    }
                    .onChange(of: currentDiffCursor) { _, newCursor in
                        if rep.differenceRowIndices.indices.contains(newCursor) {
                            let targetRowID = rep.differenceRowIndices[newCursor]
                            withAnimation {
                                proxy.scrollTo(targetRowID, anchor: .center)
                            }
                        }
                    }
                }
            }

            HStack {
                if let rep = report {
                    if rep.areIdentical {
                        Label(
                            "The two files are identical!",
                            systemImage: "checkmark.seal.fill"
                        )
                        .foregroundColor(.green)
                        .font(.headline)
                    } else {
                        Text("\(rep.differenceRowIndices.count) difference(s) found")
                            .font(.subheadline)
                            .foregroundColor(.orange)
                    }

                    Spacer()

                    Button("◀ Prev Diff (F8)") {
                        if currentDiffCursor > 0 { currentDiffCursor -= 1 }
                    }
                    .disabled(rep.differenceRowIndices.isEmpty)

                    Button("Next Diff (F7) ▶") {
                        if currentDiffCursor + 1 < rep.differenceRowIndices.count {
                            currentDiffCursor += 1
                        }
                    }
                    .disabled(rep.differenceRowIndices.isEmpty)
                }

                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(minWidth: 940, minHeight: 580)
        .onAppear {
            recompute()
        }
    }

    private func recompute() {
        report = try? CompareByContentEngine.compareFiles(
            leftPath: leftPath,
            rightPath: rightPath,
            ignoreCase: ignoreCase,
            ignoreRepeatedSpaces: ignoreSpaces,
            forceBinaryMode: binaryMode
        )
        currentDiffCursor = 0
    }

    private func diffRowColor(_ kind: DiffLineKind, isLeft: Bool) -> Color {
        switch kind {
        case .equal:
            return .clear
        case .modified:
            return Color.orange.opacity(0.22)
        case .insertedLeft:
            return isLeft ? Color.green.opacity(0.25) : Color.red.opacity(0.12)
        case .insertedRight:
            return isLeft ? Color.red.opacity(0.12) : Color.green.opacity(0.25)
        }
    }
}

// MARK: - 5. Remote FTP/SFTP Connection Manager, Disk Space Analyzer, Transfer Queue & Settings

public struct RemoteConnectionsSheetView: View {
    @ObservedObject var viewModel: CommanderViewModel
    @State private var newTitle: String = "My SFTP Server"
    @State private var newProtocol: RemoteProtocolType = .sftp
    @State private var newHost: String = "localhost"
    @State private var newPort: Int = 22
    @State private var newUser: String = ""
    @State private var newRemoteDir: String = "/"
    private func dismiss() { CommanderDialog.close(viewModel) }


    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "network")
                    .font(.system(size: 18, weight: .bold))
                Text("Connect to FTP / SFTP / WebDAV Server (Cmd+Shift+F)")
                    .font(.headline)
            }

            List {
                ForEach(viewModel.remoteProfiles) { prof in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(prof.title).font(.headline)
                            Text("\(prof.protocolType.rawValue) — \(prof.host):\(prof.port) (\(prof.remoteDirectory))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Connect") {
                            viewModel.activePanel.activeTab.vfsMode = .remote(profile: prof, remotePath: prof.remoteDirectory)
                            viewModel.activePanel.reload()
                            dismiss()
                        }
                        .buttonStyle(SquareProminentButtonStyle())
                    }
                }
            }
            .frame(height: 180)

            GroupBox(label: Text("Add New Connection Bookmark")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Title", text: $newTitle).textFieldStyle(SquareTextFieldStyle())
                        SquarePicker("Protocol", selection: $newProtocol, options: RemoteProtocolType.allCases.map { p in (value: p, title: p.rawValue) })
                    }
                    HStack {
                        TextField("Host or Path", text: $newHost).textFieldStyle(SquareTextFieldStyle())
                        TextField("Port", value: $newPort, format: .number).textFieldStyle(SquareTextFieldStyle()).frame(width: 80)
                        TextField("Username", text: $newUser).textFieldStyle(SquareTextFieldStyle())
                        TextField("Remote Dir", text: $newRemoteDir).textFieldStyle(SquareTextFieldStyle())
                    }
                    Button("Save Bookmark") {
                        viewModel.remoteProfiles.append(
                            RemoteConnectionProfile(
                                title: newTitle,
                                protocolType: newProtocol,
                                host: newHost,
                                port: newPort,
                                username: newUser,
                                remoteDirectory: newRemoteDir
                            )
                        )
                    }
                }
                .padding(6)
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 640)
    }
}

public struct DiskSpaceAnalyzerSheetView: View {
    @ObservedObject var viewModel: CommanderViewModel
    @State private var currentPath: String
    @State private var totalBytes: Int64 = 0
    @State private var entries: [DiskSpaceEntry] = []
    private func dismiss() { CommanderDialog.close(viewModel) }


    public init(viewModel: CommanderViewModel, path: String) {
        self.viewModel = viewModel
        self._currentPath = State(initialValue: path)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.pie.fill")
                    .font(.system(size: 18, weight: .bold))
                Text("Disk Space Analyzer — \(currentPath)")
                    .font(.headline)
                Spacer()
                Text(FileItem.formatByteCount(totalBytes, format: .dynamicKMGT))
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
            }

            List(entries) { entry in
                HStack(spacing: 10) {
                    Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                        .foregroundColor(entry.isDirectory ? .yellow : .blue)
                    Text(entry.name)
                        .font(.system(size: 12, weight: entry.isDirectory ? .bold : .regular, design: .monospaced))
                        .frame(width: 240, alignment: .leading)

                    SquareProgressBar(fraction: min(100, max(0, entry.percentageOfParent)) / 100)
                        .frame(width: 180)

                    Text(String(format: "%5.1f%%", entry.percentageOfParent))
                        .font(.system(size: 11.5, design: .monospaced))
                        .frame(width: 65, alignment: .trailing)

                    Text(FileItem.formatByteCount(entry.sizeBytes, format: .dynamicKMGT))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .frame(width: 95, alignment: .trailing)

                    Text("\(entry.fileCount) files")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 80, alignment: .trailing)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if entry.isDirectory {
                        currentPath = entry.fullPath
                        scan()
                    }
                }
            }
            .frame(minHeight: 320)

            HStack {
                Button("Parent Folder (..)") {
                    let parent = (currentPath as NSString).deletingLastPathComponent
                    if !parent.isEmpty {
                        currentPath = parent
                        scan()
                    }
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 780, height: 500)
        .onAppear {
            scan()
        }
    }

    private func scan() {
        let targetPath = currentPath
        Task.detached(priority: .userInitiated) {
            if let res = try? DiskSpaceAnalyzerEngine.analyzeDirectory(at: targetPath) {
                await MainActor.run {
                    if self.currentPath == targetPath {
                        self.totalBytes = res.totalBytes
                        self.entries = res.entries
                    }
                }
            }
        }
    }
}

public struct BackgroundTransferManagerSheetView: View {
    @ObservedObject var viewModel: CommanderViewModel
    private func dismiss() { CommanderDialog.close(viewModel) }


    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Background Transfer Manager")
                .font(.headline)

            if viewModel.transferQueue.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    Text("No queued or active transfer jobs.")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                Spacer()
            } else {
                List(viewModel.transferQueue) { job in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(job.title).font(.headline)
                            Spacer()
                            Text(job.state.rawValue)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.2))
                                
                        }
                        SquareProgressBar(fraction: job.progress)
                        if let err = job.errorMessage {
                            Text(err).font(.caption).foregroundColor(.red)
                        }
                    }
                }
            }

            HStack {
                Button("Clear Completed") {
                    viewModel.transferQueue.removeAll { $0.state == .completed }
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 380)
    }
}

public struct SettingsSheetView: View {
    @ObservedObject var viewModel: CommanderViewModel
    private func dismiss() { CommanderDialog.close(viewModel) }


    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("CZ.commander Configuration")
                .font(.headline)

            Form {
                SquarePicker("Color Theme:", selection: $viewModel.themeID, options: CommanderThemeID.allCases.map { t in (value: t, title: t.displayName) })

                SquarePicker("Size display format:", selection: $viewModel.sizeDisplayFormat, options: [
                    (value: FileSizeDisplayFormat.dynamicKMG, title: "Dynamic (k / M / G)"),
                    (value: FileSizeDisplayFormat.dynamicKMGT, title: "Dynamic (B / k / M / G / T)"),
                    (value: FileSizeDisplayFormat.bytes, title: "Exact Bytes (123 456 789)"),
                    (value: FileSizeDisplayFormat.kilobytes, title: "Kilobytes (123 456 k)")
                ])

                HStack {
                    Text("Font size (\(String(format: "%.1f", viewModel.fontSize)) pt):")
                    Slider(value: $viewModel.fontSize, in: 10.5...16.5, step: 0.5)
                }

                Toggle("Show hidden & dot files (Cmd+H)", isOn: $viewModel.showHiddenFiles)
                Toggle("Show top Button Bar", isOn: $viewModel.showButtonBar)
                Toggle("Show Drive Bar", isOn: $viewModel.showDriveBar)
                Toggle("Show Function Key Bar (F3-F8)", isOn: $viewModel.showFunctionKeyBar)
                Toggle("Check GitHub for updates at launch", isOn: Binding(
                    get: { UpdateChecker.shared.checksAutomatically },
                    set: { UpdateChecker.shared.checksAutomatically = $0 }
                ))
            }

            HStack {
                Spacer()
                Button("OK") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
