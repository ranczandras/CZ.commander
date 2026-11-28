import SwiftUI
import AppKit
import CZCommanderCore

// Confirmation before copying / moving / deleting (Total Commander asks every time), with the
// number of files, folders and bytes counted live while the dialog is open.

@MainActor
final class TotalsModel: ObservableObject {
    @Published var totals = SizeCounter.Totals()
    private let counter = SizeCounter()
    private var started = false

    func start(localPaths: [String], dropbox: [DropboxEntry]) {
        guard !started else { return }
        started = true
        counter.start(localPaths: localPaths, dropbox: dropbox) { [weak self] t in
            DispatchQueue.main.async { self?.totals = t }
        }
    }

    func stop() { counter.cancel() }
}

/// "Counting… 1 234 files in 56 folders, 78.9 GB" / final totals.
struct TransferTotalsLine: View {
    let localPaths: [String]
    var dropbox: [DropboxEntry] = []
    @StateObject private var model = TotalsModel()

    var body: some View {
        let t = model.totals
        HStack(spacing: 6) {
            if !t.isDone {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
            } else {
                Image(systemName: "sum").font(.system(size: 11, weight: .bold))
            }
            Text((t.isDone ? "" : "Counting… ") + "\(t.files) file(s)"
                 + (t.folders > 0 ? " in \(t.folders) folder(s)" : "") + ", " + FileItem.formatByteCount(t.bytes))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
        }
        .onAppear { model.start(localPaths: localPaths, dropbox: dropbox) }
        .onDisappear { model.stop() }
    }
}

/// A transfer waiting for OK (drag & drop, Dropbox F5 / F6).
struct PendingTransfer {
    let title: String
    let icon: String
    let from: String
    let to: String
    let localPaths: [String]
    let dropbox: [DropboxEntry]
    let names: [String]
    var onCancel: (@MainActor () -> Void)? = nil
    let start: @MainActor () -> Void
}

extension FileOperationManager {
    /// Shows the confirmation; `start` runs on OK.
    func confirm(_ pending: PendingTransfer) {
        pendingTransfers.append(pending)
        guard pendingTransfers.count == 1 else { return }  // shown after the ones before it
        showConfirmation()
    }

    private func showConfirmation() {
        let vm = viewModel ?? CommanderViewModel.shared
        MainWindowController.show()
        vm.activeSheet = .transferConfirm
    }

    /// OK / Cancel / Esc on the first pending transfer; the next one (if any) is shown after.
    func resolvePending(start: Bool) {
        guard !pendingTransfers.isEmpty else { return }
        let p = pendingTransfers.removeFirst()
        if start { p.start() } else { p.onCancel?() }
        if !pendingTransfers.isEmpty {
            DispatchQueue.main.async { self.showConfirmation() }
        }
    }
}

struct TransferConfirmSheetView: View {
    @ObservedObject var viewModel: CommanderViewModel
    @ObservedObject private var manager = FileOperationManager.shared
    @State private var decided = false

    var body: some View {
        if let p = manager.pendingTransfer {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: p.icon).font(.system(size: 18, weight: .bold))
                    Text(p.title).font(.headline).lineLimit(2)
                }
                VStack(alignment: .leading, spacing: 3) {
                    row("From:", p.from)
                    row("To:", p.to)
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(p.names.prefix(8), id: \.self) { name in
                        Text(name).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    }
                    if p.names.count > 8 {
                        Text("… and \(p.names.count - 8) more").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Rectangle().fill(Color.primary.opacity(0.05)))
                .overlay(Rectangle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                TransferTotalsLine(localPaths: p.localPaths, dropbox: p.dropbox)
                HStack {
                    Spacer()
                    Button("Cancel (Esc)") {
                        CommanderDialog.close(viewModel)  // onDisappear cancels it
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Start (Enter)") {
                        decided = true
                        CommanderDialog.close(viewModel)
                        manager.resolvePending(start: true)
                    }
                    .buttonStyle(SquareProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 560)
            .onDisappear {
                // Closed with Cancel or Esc: tell the waiting side (a Finder drop waits for it).
                if !decided { manager.resolvePending(start: false) }
            }
        } else {
            Color.clear.frame(width: 1, height: 1).onAppear { CommanderDialog.close(viewModel) }
        }
    }

    private func row(_ label: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.system(size: 11, weight: .semibold)).frame(width: 42, alignment: .leading)
            Text(text).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.head).help(text)
        }
    }
}
