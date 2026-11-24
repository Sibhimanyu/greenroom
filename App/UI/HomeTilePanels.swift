//
//  HomeTilePanels.swift
//
//  The shared shell for the popovers that open from Home's tiles (Look,
//  Camera, and the tiles to come): a compact header (title, current value,
//  one line saying what the tile does, optional art), sections, rows of choice
//  tiles, list rows for devices, toggle rows whose dependents collapse when
//  off, and a footer link into the right Settings tab.
//
//  The popover itself is the system's (it is already glass, and takes no
//  focus from anything but Home). This is only its content. Pure rules:
//  HomeTilePanelRules.swift.
//
import SwiftUI

// MARK: - Shell

struct HomeTilePanel<Content: View>: View {
    /// Shown uppercase, as the section label ("LOOK").
    let title: String
    /// The tile's one line, from its old hover card ("Which camera you appear on.").
    var summary: String?
    /// The current value, trailing on the title line.
    var value: String?
    /// An optional extra line under the summary, with an SF Symbol.
    var note: (symbol: String, text: String)?
    /// Small art at the header's leading edge (the old hover card's schematic).
    var art: AnyView?
    /// Footer link ("More look settings…"); nil hides the footer.
    var moreTitle: String?
    var onMore: (() -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content()
            if let moreTitle, let onMore {
                Button(moreTitle, action: onMore)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Brand.text)
            }
        }
        .padding(14)
    }

    @ViewBuilder private var header: some View {
        if let art {
            HStack(alignment: .center, spacing: 10) {
                // The hover card's 248x104 drawing, at half size.
                art.frame(width: 248, height: 104)
                    .scaleEffect(0.5)
                    .frame(width: 124, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                titleLines
            }
        } else {
            titleLines
        }
    }

    private var titleLines: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HomeTileLabel(text: title)
                if let value {
                    Spacer(minLength: 8)
                    Text(value)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let summary {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note {
                Label(note.text, systemImage: note.symbol)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// An uppercase section label.
struct HomeTileLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold)).tracking(0.5)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A labelled group inside a panel.
struct HomeTileSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HomeTileLabel(text: title)
            content()
        }
    }
}

// MARK: - Choice tiles

struct HomeTileChoice: Identifiable {
    var id: String
    var title: String
    var symbol: String
    var selected: Bool
}

/// A row of choice tiles: arrows move, Return picks, Esc closes the popover.
struct HomeTileChoiceRow: View {
    let choices: [HomeTileChoice]
    var tileWidth: CGFloat = 70
    var autofocus = false
    let pick: (Int) -> Void

    @State private var index = 0
    @State private var keyed = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(choices.enumerated()), id: \.element.id) { offset, choice in
                Button { pick(offset) } label: {
                    VStack(spacing: 6) {
                        Image(systemName: choice.symbol)
                            .font(.system(size: 22, weight: .regular))
                            .frame(width: 58, height: 40)
                        Text(choice.title)
                            .font(.system(size: 11, weight: choice.selected ? .semibold : .regular))
                            .foregroundStyle(choice.selected ? .primary : .secondary)
                            // One line, always: the selected label's bolder
                            // weight wrapped "Whole screen" to two lines and
                            // made that tile taller than the rest (owner, 2026-11-24).
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            // A width to scale into, or the label never shrinks.
                            .frame(maxWidth: tileWidth - 8)
                    }
                    .padding(.vertical, 6)
                    .frame(width: tileWidth)
                }
                .greenroomTile(role: .choice(selected: choice.selected), radius: 10)
                .overlay { HomeTileKeyRing(show: keyed && index == offset, radius: 10) }
                .help(choice.title)
            }
        }
        .homeTileKeys(axis: .horizontal, count: choices.count, index: $index, keyed: $keyed,
                      selected: choices.firstIndex { $0.selected }, autofocus: autofocus, pick: pick)
    }
}

// MARK: - Device list

/// One device in a list: icon (or thumbnail), name, optional trailing detail,
/// a check when selected.
struct HomeTileListRow: View {
    var symbol: String
    var title: String
    var detail: String?
    var selected: Bool
    var disabled = false
    var keyFocused = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? Brand.text : Color.secondary)
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Brand.text)
                }
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Brand.text)
                    .opacity(selected ? 1 : 0)
                    .frame(width: 14)
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(HomeTileRowStyle())
        .overlay { HomeTileKeyRing(show: keyFocused, radius: 8) }
        .disabled(disabled)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct HomeTileRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }
    private struct RowBody: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.quaternary.opacity(configuration.isPressed ? 1 : hovering && enabled ? 0.7 : 0))
                )
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovering = $0 }
        }
    }
}

/// A vertical list of rows with the same keys as the choice row.
struct HomeTileList<Row: Identifiable, RowContent: View>: View {
    let rows: [Row]
    let selected: (Row) -> Bool
    var autofocus = false
    let pick: (Int) -> Void
    @ViewBuilder let row: (Row, Bool) -> RowContent

    @State private var index = 0
    @State private var keyed = false

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { offset, item in
                row(item, keyed && index == offset)
            }
        }
        .homeTileKeys(axis: .vertical, count: rows.count, index: $index, keyed: $keyed,
                      selected: rows.firstIndex(where: selected), autofocus: autofocus, pick: pick)
    }
}

// MARK: - Toggle row

/// A switch row. Put its dependents in `HomeTileDependents` so they fold away
/// when it is off (DESIGN.md, settings: collapse, not grey).
struct HomeTileToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var help: String?

    var body: some View {
        Toggle(isOn: $isOn.animatedCollapse()) {
            Text(title).font(.system(size: 12))
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .help(help ?? title)
    }
}

/// Dependents of a toggle (or of a rule): removed and animated when `hidden`.
struct HomeTileDependents<Content: View>: View {
    let hidden: Bool
    @ViewBuilder var content: () -> Content
    var body: some View {
        Collapsible(hidden: hidden) {
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(.top, 2)
        }
    }
}

// MARK: - Keyboard

/// Faint ring on the key-focused choice (the chosen one keeps its own ring).
struct HomeTileKeyRing: View {
    let show: Bool
    let radius: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.45), lineWidth: 1.5)
            .opacity(show ? 1 : 0)
            .allowsHitTesting(false)
    }
}

private struct HomeTileKeys: ViewModifier {
    let axis: Axis
    let count: Int
    @Binding var index: Int
    @Binding var keyed: Bool
    let selected: Int?
    let autofocus: Bool
    let pick: (Int) -> Void
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onAppear {
                index = HomeTileKeyRules.startIndex(selected: selected, count: count)
                if autofocus { focused = true }
            }
            .onKeyPress { press in
                let back: KeyEquivalent = axis == .horizontal ? .leftArrow : .upArrow
                let forward: KeyEquivalent = axis == .horizontal ? .rightArrow : .downArrow
                switch press.key {
                case back: step(-1); return .handled
                case forward: step(1); return .handled
                case .return where keyed && count > 0: pick(index); return .handled
                default: return .ignored   // Esc falls through and closes the popover
                }
            }
    }

    private func step(_ delta: Int) {
        // First press shows where the keyboard is; the next ones move it.
        if keyed { index = HomeTileKeyRules.moved(from: index, by: delta, count: count) }
        keyed = true
    }
}

extension View {
    func homeTileKeys(axis: Axis, count: Int, index: Binding<Int>, keyed: Binding<Bool>,
                      selected: Int?, autofocus: Bool, pick: @escaping (Int) -> Void) -> some View {
        modifier(HomeTileKeys(axis: axis, count: count, index: index, keyed: keyed,
                              selected: selected, autofocus: autofocus, pick: pick))
    }
}
