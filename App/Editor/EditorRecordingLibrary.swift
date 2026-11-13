//
//  EditorRecordingLibrary.swift
//  Greenroom
//
//  Written for Greenroom (not ported). Replaces Recorditor's LibraryViewModel
//  and PlaybackSheet at the editor's seams: Greenroom's own recordings list
//  (ScreenroomLibrary scan of the session folders), its thumbnail cache, and a
//  small AVPlayerView sheet.
//
import AVKit
import SwiftUI

@MainActor
final class EditorRecordingLibrary: ObservableObject {
    struct Item: Identifiable {
        let url: URL
        let name: String
        let date: Date
        var id: URL { url }
    }

    @Published private(set) var items: [Item] = []

    func refresh() {
        items = ScreenroomLibrary.presentations().compactMap { p in
            guard let url = p.recording else { return nil }
            return Item(url: url, name: p.presenter, date: p.presentedAt)
        }
    }
}

/// A recording's picture from the shared thumbnail cache.
struct EditorRecordingThumb: View {
    let url: URL
    @ObservedObject private var thumbnails = SessionThumbnails.shared

    var body: some View {
        Group {
            if let image = thumbnails.image(for: url) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(Color.primary.opacity(0.06))
                    .overlay(Image(systemName: "film").foregroundStyle(.tertiary))
            }
        }
    }
}

/// A recording's length as "0:00", from the shared cache ("…" until known).
struct EditorRecordingDuration: View {
    let url: URL
    @ObservedObject private var thumbnails = SessionThumbnails.shared

    var body: some View {
        if let seconds = thumbnails.duration(for: url), seconds > 0 {
            Text(TimeFormatting.clock(seconds))
        } else {
            Text("\u{2026}")
        }
    }
}

/// Plays a saved edit.
struct EditorPlaybackSheet: View {
    let url: URL
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            Player(player: player)
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear { let p = AVPlayer(url: url); player = p; p.play() }
        .onDisappear { player?.pause(); player = nil }
    }

    private struct Player: NSViewRepresentable {
        let player: AVPlayer?
        func makeNSView(context: Context) -> AVPlayerView {
            let view = AVPlayerView()
            view.controlsStyle = .inline
            view.player = player
            return view
        }
        func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
    }
}
