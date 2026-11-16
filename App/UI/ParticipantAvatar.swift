//
//  ParticipantAvatar.swift
//  Greenroom
//
//  A person's circle: their Zoom profile photo, or their initials on a colour
//  that is the same every time for the same name.
//
import SwiftUI

struct ParticipantAvatar: View {
    let userID: UInt32
    let name: String
    var size: CGFloat = 28

    @ObservedObject private var store = ParticipantAvatarStore.shared

    var body: some View {
        Group {
            // Reading `revision` ties this body to photo changes.
            if store.revision >= 0, let image = store.image(for: userID) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(AvatarStyle.color(for: name).gradient)
                    .overlay(
                        Text(AvatarStyle.initials(for: name))
                            .font(.system(size: size * 0.38, weight: .semibold))
                            .foregroundStyle(.white)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// Initials and colour from a name, shared with the chat's model.
enum AvatarStyle {
    /// First LETTER of each word, not first character: class names like
    /// "Sibhi -8A" put a dash-word second, and taking characters rendered the
    /// avatar as "S-". Words with no letter at all are skipped.
    static func initials(for name: String) -> String {
        let letters = name.split(separator: " ").compactMap { word in
            word.first(where: { $0.isLetter }).map(String.init)
        }.prefix(2)
        if letters.isEmpty { return name.first.map { String($0).uppercased() } ?? "?" }
        return letters.joined().uppercased()
    }

    /// Stable per-person colour, derived from the name.
    static func color(for name: String) -> Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .red]
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFFFF }
        return palette[hash % palette.count]
    }
}
