//
//  SessionsRow.swift
//
//  One row of the Sessions timeline: the picture with its length, the title,
//  what kind and when, and the chips that say what is left to do. Watch,
//  Share and More appear on hover and while the row has the keyboard.
//  When a search matches what was said, the matching sentences sit under the
//  row, each with its time; a click opens the session at that moment.
//
import AppKit
import SwiftUI

struct SessionRow<Menu: View>: View {
    let card: SessionCardModel
    let image: NSImage?
    let now: Date
    var selected = false
    var hits: [TranscriptHit] = []
    var term = ""
    var onSelect: () -> Void = {}
    var onOpen: () -> Void = {}
    var onOpenAt: (Double) -> Void = { _ in }
    @ViewBuilder let menu: () -> Menu

    @State private var hovering = false
    @State private var showAllHits = false
    @FocusState private var focused: Bool

    private var hitLimit: Int { 3 }
    private var thumbWidth: CGFloat { 144 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .trailing) {
                Button(action: onSelect) { rowBody }
                    .greenroomTile(role: .browse, radius: 12)
                    .focused($focused)
                    // Double-click opens. Simultaneous, so the button's own
                    // single click still selects.
                    .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen() })
                    .onKeyPress(.return) { onOpen(); return .handled }
                    .contextMenu { menu() }
                if hovering || focused { actions.padding(.trailing, 10) }
            }
            .onHover { hovering = $0 }
            if !hits.isEmpty { hitList }
        }
        .padding(.bottom, 2)
    }

    // MARK: Row

    private var rowBody: some View {
        HStack(spacing: 16) {
            SessionThumbnail(image: image, kind: card.kind, radius: 8)
                .frame(width: thumbWidth, height: thumbWidth * 9 / 16)
                .overlay(alignment: .bottomTrailing) {
                    if let d = card.duration {
                        Text(SessionsFormat.clock(d))
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.6)))
                            .padding(5)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(card.kind.label) \u{00B7} \(SessionsFormat.time(card.date))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
                chips
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Brand.green.opacity(0.10) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Brand.green, lineWidth: 2).opacity(selected ? 1 : 0))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var chips: some View {
        let items = SessionChips.chips(for: card)
        if !items.isEmpty {
            HStack(spacing: 6) {
                ForEach(items) { SessionChipView(chip: $0) }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { onOpen() } label: { Label("Watch", systemImage: "play.fill") }
            if card.hasVideo && !card.isUploaded {
                // The session's page holds Share; this is the shortcut to it.
                Button { onOpen() } label: { Label("Share\u{2026}", systemImage: "square.and.arrow.up") }
                    .tint(Brand.net)
            }
            SwiftUI.Menu { menu() } label: { Image(systemName: "ellipsis") }
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More")
        }
        .font(.callout.weight(.medium))
        .greenroomGlassButton()
        .controlSize(.regular)
        .transition(.opacity)
    }

    // MARK: Transcript results

    private var hitList: some View {
        let shown = showAllHits ? hits : Array(hits.prefix(hitLimit))
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(shown) { hit in
                Button { onOpenAt(hit.seconds) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(hit.clock)
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(Brand.text)
                            .frame(width: 44, alignment: .trailing)
                        Text(Self.highlighted(hit.text, term: term))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
                }
                .greenroomTile(role: .browse, radius: 8)
                .help("Open at \(hit.clock)")
                .accessibilityLabel("At \(hit.clock): \(hit.text)")
            }
            if hits.count > hitLimit {
                Button(showAllHits ? "Show fewer" : "Show all \(hits.count) matches") {
                    withAnimation(.snappy(duration: 0.2)) { showAllHits.toggle() }
                }
                .buttonStyle(.plain)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.leading, 62)
                .padding(.top, 2)
            }
        }
        .padding(.leading, 10 + thumbWidth + 16 - 62)
        .padding(.bottom, 6)
    }

    /// The matched words in bold, so the eye lands on why this sentence is here.
    static func highlighted(_ text: String, term: String) -> AttributedString {
        var out = AttributedString(text)
        for word in term.split(whereSeparator: \.isWhitespace) {
            var from = out.startIndex
            while let r = out[from...].range(of: String(word),
                                             options: [.caseInsensitive, .diacriticInsensitive]) {
                out[r].font = .callout.weight(.bold)
                out[r].foregroundColor = .primary
                from = r.upperBound
            }
        }
        return out
    }
}

/// A status pill (DESIGN.md: radius pill). Amber text uses `Brand.netText`
/// and green text `Brand.text`; both fills are the same hue at low opacity.
struct SessionChipView: View {
    let chip: SessionChip

    var body: some View {
        HStack(spacing: 4) {
            if let symbol = chip.symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            } else if chip.tone == .amber {
                Circle().fill(Brand.net).frame(width: 6, height: 6)
            }
            Text(chip.text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(fill))
    }

    private var foreground: AnyShapeStyle {
        switch chip.tone {
        case .amber: return AnyShapeStyle(Brand.netText)
        case .green: return AnyShapeStyle(Brand.text)
        case .plain: return AnyShapeStyle(.secondary)
        }
    }

    private var fill: Color {
        switch chip.tone {
        case .amber: return Brand.net.opacity(0.14)
        case .green: return Brand.green.opacity(0.14)
        case .plain: return Color.secondary.opacity(0.12)
        }
    }
}
