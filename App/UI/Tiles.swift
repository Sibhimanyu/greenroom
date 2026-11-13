//
//  Tiles.swift
//
//  The one style for every clickable card or tile (DESIGN.md, "Cards and
//  tiles"). Browse tiles (Sessions) have no box at rest; choice tiles (Settings,
//  onboarding) rest on `.quinary` and show "chosen" as a 2pt accent ring plus a
//  checkmark, never a green wash. Every tile lifts 1pt and gains a soft shadow
//  under the pointer; under Reduce Motion only the fill changes.
//
//  Hover state lives in the style's body, not in the grid that holds the
//  tiles, so a LazyVGrid refresh does not reset it. The keyboard focus ring is
//  the system's: never apply `.focusEffectDisabled()` to a tile.
//
import SwiftUI

struct GreenroomTileStyle: ButtonStyle {
    var role: GreenroomTileRole
    var radius: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        TileBody(configuration: configuration, role: role, radius: radius)
    }

    private struct TileBody: View {
        let configuration: ButtonStyle.Configuration
        let role: GreenroomTileRole
        let radius: CGFloat
        @State private var hovering = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let look = TileAppearance.resolve(
                role: role,
                hovering: hovering && enabled,
                pressed: configuration.isPressed,
                reduceMotion: reduceMotion)
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

            configuration.label
                .background { fillView(look.fill, in: shape) }
                .overlay {
                    if case .choice = role {
                        shape.strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                    }
                }
                .overlay {
                    if look.showsSelectionRing {
                        shape.strokeBorder(Brand.green, lineWidth: 2)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if look.showsSelectionRing {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Brand.green)
                            .font(.system(size: 15))
                            .padding(6)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(shape)
                .scaleEffect(look.scale)
                .offset(y: look.offsetY)
                .shadow(color: .black.opacity(look.shadowOpacity), radius: 6, y: 2)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
                .onHover { hovering = $0 }
                .accessibilityAddTraits(selectedTrait)
        }

        private var selectedTrait: AccessibilityTraits {
            if case .choice(let selected) = role, selected { return .isSelected }
            return []
        }

        @ViewBuilder
        private func fillView(_ fill: TileFill, in shape: RoundedRectangle) -> some View {
            switch fill {
            case .none: Color.clear
            case .quinary: shape.fill(.quinary)
            case .quaternary: shape.fill(.quaternary)
            }
        }
    }
}

extension View {
    /// Wrap a tile's label in a `Button` and call this on the button. The
    /// button already carries `.isButton`; a choice tile adds `.isSelected`.
    func greenroomTile(role: GreenroomTileRole, radius: CGFloat = 10) -> some View {
        buttonStyle(GreenroomTileStyle(role: role, radius: radius))
    }
}

#Preview("Tiles") {
    VStack(spacing: 20) {
        HStack(spacing: 16) {
            ForEach(["Class", "Talk"], id: \.self) { name in
                Button {} label: {
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 10).fill(.gray.opacity(0.3))
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        Text(name).font(.headline)
                    }
                    .padding(6)
                    .frame(width: 180)
                }
                .greenroomTile(role: .browse)
            }
        }
        HStack(spacing: 16) {
            ForEach([false, true], id: \.self) { chosen in
                Button {} label: {
                    Label(chosen ? "Chosen" : "Rest", systemImage: "square.grid.2x2")
                        .frame(width: 140, height: 56)
                }
                .greenroomTile(role: .choice(selected: chosen))
            }
        }
    }
    .padding(24)
}
