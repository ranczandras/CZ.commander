import SwiftUI
import AppKit
import CZCommanderCore

// CZ.commander draws every control with square corners. Native macOS controls (bordered buttons,
// checkboxes, group boxes, pop-up and segmented pickers, sheets) are rounded, so the app uses
// these replacements, applied globally from `MainCommanderWindowView` via `.squareControls()`.

private enum SquareColors {
    static var fill: Color { Color(nsColor: .controlColor) }
    static var fieldFill: Color { Color(nsColor: .textBackgroundColor) }
    static var border: Color { Color(nsColor: .separatorColor) }
    static var strongBorder: Color { Color(nsColor: .tertiaryLabelColor) }
}

// MARK: - Buttons

/// Default push button: square, hairline border, pressed tint.
struct SquareButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Rectangle().fill(configuration.isPressed ? Color.accentColor.opacity(0.25) : SquareColors.fill))
            .overlay(Rectangle().stroke(SquareColors.strongBorder, lineWidth: 0.8))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

// MARK: - Toggles

/// Checkbox with a square box.
struct SquareCheckboxToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 5) {
                ZStack {
                    Rectangle().fill(configuration.isOn ? Color.accentColor : SquareColors.fieldFill)
                    Rectangle().stroke(configuration.isOn ? Color.accentColor : SquareColors.strongBorder, lineWidth: 1)
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .heavy))
                            .foregroundColor(.white)
                    }
                }
                .frame(width: 13, height: 13)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Toggle drawn as a square push button that stays highlighted while on (replaces `.toggleStyle(.button)`).
struct SquareButtonToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Rectangle().fill(configuration.isOn ? Color.accentColor.opacity(0.85) : SquareColors.fill))
                .foregroundColor(configuration.isOn ? .white : .primary)
                .overlay(Rectangle().stroke(SquareColors.strongBorder, lineWidth: 0.8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Group box

struct SquareGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            configuration.label
                .font(.system(size: 11, weight: .semibold))
            configuration.content
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Rectangle().fill(Color.primary.opacity(0.03)))
                .overlay(Rectangle().stroke(SquareColors.border, lineWidth: 1))
        }
    }
}

// MARK: - Picker

enum SquarePickerKind {
    case menu, segmented, radio
}

/// Square replacement for `Picker` (pop-up menu, segmented control or radio group).
struct SquarePicker<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    var kind: SquarePickerKind = .menu

    init(_ label: String, selection: Binding<Value>, options: [(value: Value, title: String)], kind: SquarePickerKind = .menu) {
        self.label = label
        self._selection = selection
        self.options = options
        self.kind = kind
    }

    private var currentTitle: String {
        options.first(where: { $0.value == selection })?.title ?? ""
    }

    var body: some View {
        switch kind {
        case .radio:
            VStack(alignment: .leading, spacing: 4) {
                if !label.isEmpty { Text(label) }
                control
            }
        default:
            HStack(spacing: 6) {
                if !label.isEmpty { Text(label) }
                control
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        switch kind {
        case .menu:
            Menu {
                ForEach(options.indices, id: \.self) { i in
                    Button {
                        selection = options[i].value
                    } label: {
                        if options[i].value == selection {
                            Label(options[i].title, systemImage: "checkmark")
                        } else {
                            Text(options[i].title)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(currentTitle)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Rectangle().fill(SquareColors.fieldFill))
                .overlay(Rectangle().stroke(SquareColors.strongBorder, lineWidth: 0.8))
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)

        case .segmented:
            HStack(spacing: 0) {
                ForEach(options.indices, id: \.self) { i in
                    let isOn = options[i].value == selection
                    Button {
                        selection = options[i].value
                    } label: {
                        Text(options[i].title)
                            .font(.system(size: 11, weight: isOn ? .semibold : .regular))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity)
                            .background(Rectangle().fill(isOn ? Color.accentColor.opacity(0.85) : SquareColors.fill))
                            .foregroundColor(isOn ? .white : .primary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if i < options.count - 1 {
                        Rectangle().fill(SquareColors.strongBorder).frame(width: 0.8)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .overlay(Rectangle().stroke(SquareColors.strongBorder, lineWidth: 0.8))

        case .radio:
            VStack(alignment: .leading, spacing: 3) {
                ForEach(options.indices, id: \.self) { i in
                    let isOn = options[i].value == selection
                    Button {
                        selection = options[i].value
                    } label: {
                        HStack(spacing: 5) {
                            ZStack {
                                Rectangle().fill(SquareColors.fieldFill)
                                Rectangle().stroke(isOn ? Color.accentColor : SquareColors.strongBorder, lineWidth: 1)
                                if isOn { Rectangle().fill(Color.accentColor).padding(3) }
                            }
                            .frame(width: 13, height: 13)
                            Text(options[i].title)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Progress bar

struct SquareProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.primary.opacity(0.08))
                Rectangle().fill(Color.accentColor)
                    .frame(width: geo.size.width * min(1, max(0, fraction)))
            }
            .overlay(Rectangle().stroke(SquareColors.border, lineWidth: 0.8))
        }
        .frame(height: 8)
    }
}

// MARK: - Tabs (replaces the rounded TabView header)

struct SquareTabBar: View {
    let titles: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(titles.indices, id: \.self) { i in
                let isOn = i == selection
                Button {
                    selection = i
                } label: {
                    Text(titles[i])
                        .font(.system(size: 11.5, weight: isOn ? .semibold : .regular))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Rectangle().fill(isOn ? Color(nsColor: .windowBackgroundColor) : SquareColors.fill))
                        .overlay(Rectangle().stroke(SquareColors.border, lineWidth: 0.8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - In-window square dialog (replaces rounded `.sheet`)

/// Presents dialog content inside the main window with a square frame instead of a rounded sheet window.
struct SquareModalHost<Content: View>: View {
    let content: Content
    let onCancel: () -> Void

    init(onCancel: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.onCancel = onCancel
        self.content = content()
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle()
                    .fill(Color.black.opacity(0.28))
                    .contentShape(Rectangle())
                    .onTapGesture {}   // swallow clicks behind the dialog
                // Size to the content's ideal size like a sheet did (min sizes of large tools still apply).
                content
                    .fixedSize()
                    .background(
                        Rectangle()
                            .fill(Color(nsColor: .windowBackgroundColor))
                            .shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 6)
                    )
                    .overlay(Rectangle().stroke(SquareColors.strongBorder, lineWidth: 1))
                    .onAppear(perform: focusFirstField)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// Move keyboard focus from the file panels into the dialog's first (top-most) text field.
    private func focusFirstField() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard let window = MainWindowController.window, let root = window.contentView else { return }
            var fields: [NSTextField] = []
            func collect(_ view: NSView) {
                if let tf = view as? NSTextField, tf.isEditable, !tf.isHiddenOrHasHiddenAncestor, tf.window != nil {
                    fields.append(tf)
                }
                view.subviews.forEach(collect)
            }
            collect(root)
            let first = fields.min { a, b in
                let ra = a.convert(a.bounds, to: nil), rb = b.convert(b.bounds, to: nil)
                return ra.maxY != rb.maxY ? ra.maxY > rb.maxY : ra.minX < rb.minX
            }
            if let first { window.makeFirstResponder(first) }
        }
    }
}

extension View {
    /// Applies the square control styles to every control below this view.
    func squareControls() -> some View {
        self
            .buttonStyle(SquareButtonStyle())
            .toggleStyle(SquareCheckboxToggleStyle())
            .groupBoxStyle(SquareGroupBoxStyle())
            .textFieldStyle(SquareTextFieldStyle())
            .listStyle(.plain)
    }
}

/// Closes the current in-window dialog and gives the keyboard back to the file panels.
@MainActor
enum CommanderDialog {
    static func close(_ viewModel: CommanderViewModel) {
        viewModel.activeSheet = nil
        DispatchQueue.main.async { CommanderKeyboardRouter.shared.focusKeyCaptureView() }
    }
}

// MARK: - Text field and stepper

/// Text field with a square border (macOS 26 rounds even `.squareBorder`).
struct SquareTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(Rectangle().fill(SquareColors.fieldFill))
            .overlay(Rectangle().stroke(SquareColors.strongBorder, lineWidth: 0.8))
    }
}

/// Square replacement for `Stepper`.
struct SquareStepper: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    init(_ label: String, value: Binding<Int>, in range: ClosedRange<Int>) {
        self.label = label
        self._value = value
        self.range = range
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
            HStack(spacing: 0) {
                stepButton("minus") { value = max(range.lowerBound, value - 1) }
                    .disabled(value <= range.lowerBound)
                Rectangle().fill(SquareColors.strongBorder).frame(width: 0.8, height: 16)
                stepButton("plus") { value = min(range.upperBound, value + 1) }
                    .disabled(value >= range.upperBound)
            }
            .overlay(Rectangle().stroke(SquareColors.strongBorder, lineWidth: 0.8))
        }
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 16)
                .background(Rectangle().fill(SquareColors.fill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
