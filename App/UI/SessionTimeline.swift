//
//  SessionTimeline.swift
//
//  The watch page's one timeline, always under the picture: play and pause,
//  the time, a thin track with the marks drawn on it and a knob you can drag,
//  the length, and the speed. It replaces AVKit's scrubber and the old marks
//  lane, so the controls and the marks are the same thing.
//
//  Plain values and closures, like the rest of the page: the player lives in
//  RecordingsView, the off-screen render passes sample numbers.
//
import SwiftUI

/// Colours of the marks, shared by the track and the Moments list so a dot
/// in the list is the same colour as its tick on the timeline.
enum SessionMarkStyle {
    /// Clips are the green blocks (a fill, never text).
    static let clip = Brand.fill
    /// Notes are tall thin ticks in a system teal, apart from the green.
    static let note = Color(nsColor: .systemTeal)
    static let filler = Color.primary.opacity(0.28)
}

struct SessionTimeline: View {
    /// Fillers and notes from the analysis, in seconds.
    struct Marks {
        var fillers: [Double] = []
        var notes: [Double] = []
        var isEmpty: Bool { fillers.isEmpty && notes.isEmpty }
    }

    let duration: Double
    let playhead: Double
    let isPlaying: Bool
    let clips: [SessionClip]
    var marks = Marks()
    var rate: Float = 1
    var skipping = false
    var onStopSkipping: () -> Void = {}
    var onTogglePlay: () -> Void = {}
    /// Called on a click and continuously while the knob is dragged.
    var onSeek: (Double) -> Void = { _ in }
    var onRate: (Float) -> Void = { _ in }

    /// Where the knob is while it is held, so the player's own ticks do not
    /// fight the hand.
    @State private var dragFraction: Double?

    private let trackHeight: CGFloat = 4
    private let hitHeight: CGFloat = 28
    private let knob: CGFloat = 14

    private var shownFraction: Double {
        dragFraction ?? SessionDetailRules.fraction(of: playhead, in: duration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                playButton
                Text(SessionDetailRules.clock(shownFraction * duration))
                    .font(.system(size: 12, design: .monospaced))
                    .monospacedDigit()
                    .frame(minWidth: 40, alignment: .trailing)
                track
                Text(SessionDetailRules.clock(duration))
                    .font(.system(size: 12, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 40, alignment: .leading)
                speedMenu
            }
            if skipping {
                HStack(spacing: 6) {
                    Text("Playing without fillers")
                    Button("Stop", action: onStopSkipping).buttonStyle(.link)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.leading, 40)
            }
        }
    }

    // MARK: Pieces

    private var playButton: some View {
        Button(action: onTogglePlay) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(isPlaying ? "Pause (Space)" : "Play (Space)")
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }

    private var speedMenu: some View {
        Menu {
            ForEach(SessionDetailRules.speeds, id: \.self) { speed in
                Button {
                    onRate(speed)
                } label: {
                    if speed == rate {
                        Label(SessionDetailRules.speedLabel(speed), systemImage: "checkmark")
                    } else {
                        Text(SessionDetailRules.speedLabel(speed))
                    }
                }
            }
        } label: {
            Text(SessionDetailRules.speedLabel(rate))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .monospacedDigit()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        .help("Playback speed")
    }

    /// Thin rounded track; the played part filled; clips as blocks a little
    /// taller than the track; notes as tall thin ticks; fillers as short faint
    /// ones; a knob. One drag gesture over all of it.
    private var track: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let mid = geo.size.height / 2
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.14))
                    .frame(height: trackHeight)
                Capsule()
                    .fill(Color.primary.opacity(0.62))
                    .frame(width: max(trackHeight, width * shownFraction), height: trackHeight)
                if duration > 0 {
                    ForEach(clips) { clip in
                        let start = SessionDetailRules.fraction(of: clip.startSeconds, in: duration)
                        let span = max(0.004, Double(clip.durationMs) / 1000 / duration)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(SessionMarkStyle.clip)
                            .frame(width: max(3, width * span), height: 10)
                            .offset(x: width * start)
                    }
                    ForEach(Array(marks.fillers.enumerated()), id: \.offset) { _, at in
                        Capsule()
                            .fill(SessionMarkStyle.filler)
                            .frame(width: 1.5, height: 7)
                            .offset(x: width * SessionDetailRules.fraction(of: at, in: duration) - 0.75)
                    }
                    ForEach(Array(marks.notes.enumerated()), id: \.offset) { _, at in
                        Capsule()
                            .fill(SessionMarkStyle.note)
                            .frame(width: 2.5, height: 18)
                            .offset(x: width * SessionDetailRules.fraction(of: at, in: duration) - 1.25)
                    }
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .frame(width: knob, height: knob)
                        .offset(x: width * shownFraction - knob / 2)
                }
            }
            .frame(height: geo.size.height, alignment: .center)
            .position(x: width / 2, y: mid)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard let time = SessionDetailRules.seekTime(x: value.location.x, width: width,
                                                                     duration: duration) else { return }
                        dragFraction = SessionDetailRules.fraction(of: time, in: duration)
                        onSeek(time)
                    }
                    .onEnded { _ in dragFraction = nil })
        }
        .frame(height: hitHeight)
        .help("Click or drag to jump. Green blocks are clips, tall ticks are notes.")
        .accessibilityElement()
        .accessibilityLabel("Timeline")
        .accessibilityValue("\(SessionDetailRules.clock(playhead)) of \(SessionDetailRules.clock(duration))")
        .accessibilityAdjustableAction { direction in
            let step = 5.0
            switch direction {
            case .increment: onSeek(min(duration, playhead + step))
            case .decrement: onSeek(max(0, playhead - step))
            @unknown default: break
            }
        }
    }
}
