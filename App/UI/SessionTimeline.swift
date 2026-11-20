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

/// Colours of the marks, shared by the track and the Notes list so a dot
/// in the list is the same colour as its tick on the timeline.
enum SessionMarkStyle {
    /// Clips are the green blocks (a fill, never text).
    static let clip = Brand.fill
    /// Notes are tall thin ticks in a system teal, apart from the green.
    static let note = Color(nsColor: .systemTeal)
    static let filler = Color.primary.opacity(0.28)
}

private struct TrackFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
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
    /// Notes and clips for the lane under the track; no lane when empty.
    var moments: [SessionMoment] = []
    var onSeekMoment: (SessionMoment) -> Void = { _ in }
    var onStopSkipping: () -> Void = {}
    var onTogglePlay: () -> Void = {}
    /// Called on a click and continuously while the knob is dragged.
    var onSeek: (Double) -> Void = { _ in }
    var onRate: (Float) -> Void = { _ in }
    /// Standard video controls: volume 0...1, mute, skip by seconds, full screen.
    var volume: Float = 1
    var muted = false
    var isFullScreen = false
    var onSkip: (Double) -> Void = { _ in }
    var onMute: () -> Void = {}
    var onVolume: (Float) -> Void = { _ in }
    var onFullScreen: () -> Void = {}

    /// The pointer is over the speaker: its slider is open.
    @State private var hoveringVolume = false
    /// Where the knob is while it is held, so the player's own ticks do not
    /// fight the hand.
    @State private var dragFraction: Double?
    /// The track's frame inside the timeline, so the lane lines up with it.
    @State private var trackFrame: CGRect = .zero

    private let trackHeight: CGFloat = 4
    private let hitHeight: CGFloat = 28
    private let knob: CGFloat = 14

    private var shownFraction: Double {
        dragFraction ?? SessionDetailRules.fraction(of: playhead, in: duration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    skipButton(-PlayerControlRules.skipSeconds)
                    playButton
                    skipButton(PlayerControlRules.skipSeconds)
                }
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
                volumeControl
                speedMenu
                fullScreenButton
            }
            if !moments.isEmpty, duration > 0, trackFrame.width > 0 {
                momentsLane
                    .frame(width: trackFrame.width, height: 22)
                    .padding(.leading, trackFrame.minX)
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
        .coordinateSpace(name: "sessionTimeline")
    }

    // MARK: Pieces

    /// A thin strip under the scrubber: one marker per note or clip, at its
    /// time. A click seeks there.
    private var momentsLane: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.06)).frame(height: 2)
                ForEach(moments) { moment in
                    let x = geo.size.width * SessionDetailRules.fraction(of: moment.at, in: duration)
                    Button { onSeekMoment(moment) } label: {
                        Group {
                            if moment.kind == .clip {
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(SessionMarkStyle.clip)
                                    .frame(width: 8, height: 10)
                            } else {
                                Capsule().fill(SessionMarkStyle.note).frame(width: 3, height: 14)
                            }
                        }
                        .frame(width: 18, height: 22)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(moment.label)
                    .accessibilityLabel(moment.label)
                    .offset(x: x - 9)
                }
            }
            .frame(height: geo.size.height)
        }
    }

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

    /// The shared look of a round transport button.
    private func roundGlyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 28, height: 28)
            .background(Circle().fill(Color.primary.opacity(0.08)))
            .contentShape(Circle())
    }

    private func skipButton(_ delta: Double) -> some View {
        let back = delta < 0
        let seconds = Int(abs(delta))
        return Button { onSkip(delta) } label: {
            roundGlyph(back ? "gobackward.\(seconds)" : "goforward.\(seconds)")
        }
        .buttonStyle(.plain)
        .help(back ? "Back \(seconds) seconds (\u{2190})" : "Forward \(seconds) seconds (\u{2192})")
        .accessibilityLabel(back ? "Back \(seconds) seconds" : "Forward \(seconds) seconds")
    }

    /// Mute on click; the level slider opens beside it while the pointer is
    /// over the speaker (the track gives up the width, so nothing overflows).
    private var volumeControl: some View {
        HStack(spacing: 6) {
            Button(action: onMute) {
                roundGlyph(PlayerControlRules.volumeSymbol(volume: volume, muted: muted))
            }
            .buttonStyle(.plain)
            .help(muted ? "Unmute (M)" : "Mute (M)")
            .accessibilityLabel(muted ? "Unmute" : "Mute")
            if hoveringVolume {
                Slider(value: Binding(get: { Double(muted ? 0 : volume) },
                                      set: { onVolume(Float($0)) }),
                       in: 0...1)
                    .controlSize(.mini)
                    .frame(width: 64)
                    .help("Volume")
                    .accessibilityLabel("Volume")
                    .transition(.opacity)
            }
        }
        .onHover { hoveringVolume = $0 }
        .animation(.easeOut(duration: 0.2), value: hoveringVolume)
    }

    private var fullScreenButton: some View {
        Button(action: onFullScreen) {
            roundGlyph(isFullScreen ? "arrow.down.right.and.arrow.up.left"
                                    : "arrow.up.left.and.arrow.down.right")
        }
        .buttonStyle(.plain)
        .help(isFullScreen ? "Exit full screen (F or Esc)" : "Full screen (F)")
        .accessibilityLabel(isFullScreen ? "Exit full screen" : "Full screen")
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
        .background(GeometryReader { proxy in
            Color.clear.preference(key: TrackFrameKey.self, value: proxy.frame(in: .named("sessionTimeline")))
        })
        .onPreferenceChange(TrackFrameKey.self) { trackFrame = $0 }
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
