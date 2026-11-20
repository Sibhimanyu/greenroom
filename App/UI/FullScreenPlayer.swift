//
//  FullScreenPlayer.swift
//
//  Full screen for the watch page's player: a borderless window over the
//  display, black, with the picture and the same control bar floating on glass.
//  A window of its own rather than the main window's native full screen: that
//  would drag the sidebar, the toolbar and the page's resizing choreography
//  (WindowFrameRules) into it, and the picture needs none of them. It shares
//  the page's AVPlayer, so position, speed and volume carry both ways.
//
//  Controls and the cursor hide after PlayerControlRules.hideAfter without
//  mouse movement and return on move. Keys come from PlayerControlRules.
//
import SwiftUI
import AVKit
import Combine

/// The volume a person last chose, kept across sessions.
enum PlayerVolumeStore {
    static func saved() -> Float {
        let value = UserDefaults.standard.object(forKey: PlayerControlRules.volumeKey) as? Double
        return PlayerControlRules.clampedVolume(value)
    }
    static func save(_ volume: Float) {
        UserDefaults.standard.set(Double(volume), forKey: PlayerControlRules.volumeKey)
    }
}

/// What the full-screen bar reads and does, straight off the player.
final class WatchPlayerState: ObservableObject {
    let player: AVPlayer
    @Published var playhead: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    @Published var rate: Float = 1
    @Published var volume: Float = 1
    @Published var muted = false
    @Published var controlsShown = true
    var overBar = false

    private var timeObserver: Any?
    private var bag: [AnyCancellable] = []

    init(player: AVPlayer) {
        self.player = player
        playhead = player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0
        isPlaying = player.timeControlStatus != .paused
        rate = player.defaultRate > 0 ? player.defaultRate : 1
        volume = player.volume
        muted = player.isMuted
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
                if time.seconds.isFinite { self?.playhead = time.seconds }
            }
        bag = [
            player.publisher(for: \.timeControlStatus).receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.isPlaying = $0 != .paused },
            player.publisher(for: \.volume).receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.volume = $0 },
            player.publisher(for: \.isMuted).receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.muted = $0 },
            player.publisher(for: \.defaultRate).receive(on: DispatchQueue.main)
                .sink { [weak self] in if $0 > 0 { self?.rate = $0 } },
        ]
        if let item = player.currentItem {
            bag.append(item.publisher(for: \.duration).receive(on: DispatchQueue.main)
                .sink { [weak self] in
                    let seconds = $0.seconds
                    if seconds.isFinite { self?.duration = seconds }
                })
        }
    }

    func stop() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        bag = []
    }

    deinit { stop() }

    func togglePlay() {
        if player.timeControlStatus == .paused {
            if duration > 0, playhead >= duration - 0.2 { scrub(to: 0) }
            player.play()
        } else {
            player.pause()
        }
    }

    func scrub(to seconds: Double) {
        playhead = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(_ delta: Double) {
        scrub(to: PlayerControlRules.skipTarget(from: playhead, by: delta, duration: duration))
    }

    func setRate(_ new: Float) {
        rate = new
        player.defaultRate = new
        if player.timeControlStatus != .paused { player.rate = new }
    }

    func toggleMute() { player.isMuted.toggle() }

    func setVolume(_ new: Float) {
        let level = PlayerControlRules.clampedVolume(Double(new))
        player.volume = level
        PlayerVolumeStore.save(level)
        player.isMuted = PlayerControlRules.mutedAfterSetting(volume: level, muted: player.isMuted)
    }
}

// MARK: - Window

private final class FullScreenWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class WatchFullScreen {
    static let shared = WatchFullScreen()

    private var window: NSWindow?
    private var state: WatchPlayerState?
    private var keyMonitor: Any?
    private var moveMonitor: Any?
    private var timer: Timer?
    private var lastActivity = Date()
    private var cursorHidden = false
    private var savedPresentation: NSApplication.PresentationOptions = []

    var isOpen: Bool { window != nil }

    func toggle(player: AVPlayer?) {
        if isOpen { close() } else if let player { open(player: player) }
    }

    func open(player: AVPlayer) {
        guard window == nil else { return }
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let state = WatchPlayerState(player: player)
        self.state = state
        let created = FullScreenWindow(contentRect: screen.frame, styleMask: [.borderless],
                                       backing: .buffered, defer: false, screen: screen)
        created.setFrame(screen.frame, display: false)
        created.level = .mainMenu + 1
        created.backgroundColor = .black
        created.isOpaque = true
        created.hasShadow = false
        created.isReleasedWhenClosed = false
        created.acceptsMouseMovedEvents = true
        created.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        created.appearance = NSAppearance(named: .darkAqua)
        created.contentView = NSHostingView(rootView: FullScreenPlayerRoot(
            state: state, onExit: { [weak self] in self?.close() }))
        window = created

        savedPresentation = NSApp.presentationOptions
        NSApp.presentationOptions = savedPresentation.union([.hideDock, .hideMenuBar])
        NSApp.activate(ignoringOtherApps: true)
        created.makeKeyAndOrderFront(nil)
        noteActivity()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let modifiers = !event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            guard let action = PlayerControlRules.action(keyCode: event.keyCode, hasModifiers: modifiers,
                                                         fullScreen: true) else { return event }
            self.noteActivity()
            self.perform(action)
            return nil
        }
        moveMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .scrollWheel]) { [weak self] event in
                if event.window === self?.window { self?.noteActivity() }
                return event
            }
        let tick = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
    }

    func close() {
        guard let window else { return }
        timer?.invalidate(); timer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let moveMonitor { NSEvent.removeMonitor(moveMonitor) }
        keyMonitor = nil; moveMonitor = nil
        showCursor()
        NSApp.presentationOptions = savedPresentation
        let parent = NSApp.windows.first { $0 !== window && $0.isVisible && $0.canBecomeMain }
        window.orderOut(nil)
        window.contentView = nil
        self.window = nil
        state?.stop()
        state = nil
        parent?.makeKeyAndOrderFront(nil)
    }

    private func perform(_ action: PlayerKeyAction) {
        guard let state else { return }
        switch action {
        case .playPause: state.togglePlay()
        case .skipBack: state.skip(-PlayerControlRules.skipSeconds)
        case .skipForward: state.skip(PlayerControlRules.skipSeconds)
        case .toggleMute: state.toggleMute()
        case .toggleFullScreen, .exitFullScreen: close()
        }
    }

    private func noteActivity() {
        lastActivity = Date()
        if state?.controlsShown == false { state?.controlsShown = true }
        showCursor()
    }

    private func tick() {
        guard let state else { return }
        let visible = PlayerControlRules.controlsVisible(now: Date(), lastActivity: lastActivity,
                                                         holding: state.overBar)
        if visible != state.controlsShown { state.controlsShown = visible }
        if !visible, !cursorHidden {
            NSCursor.hide()
            cursorHidden = true
        }
    }

    private func showCursor() {
        if cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
    }
}

// MARK: - Views

private struct FullScreenPicture: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

private struct FullScreenPlayerRoot: View {
    @ObservedObject var state: WatchPlayerState
    let onExit: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            FullScreenPicture(player: state.player)
                .overlay {
                    // A click plays or pauses at once; a double click leaves.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { state.togglePlay() }
                        .simultaneousGesture(TapGesture(count: 2).onEnded { onExit() })
                }
            SessionTimeline(duration: state.duration,
                            playhead: state.playhead,
                            isPlaying: state.isPlaying,
                            clips: [],
                            rate: state.rate,
                            onTogglePlay: state.togglePlay,
                            onSeek: state.scrub,
                            onRate: state.setRate,
                            volume: state.volume,
                            muted: state.muted,
                            isFullScreen: true,
                            onSkip: state.skip,
                            onMute: state.toggleMute,
                            onVolume: state.setVolume,
                            onFullScreen: onExit)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: 900)
                .greenroomGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .onHover { state.overBar = $0 }
                .padding(24)
                .opacity(state.controlsShown ? 1 : 0)
                .allowsHitTesting(state.controlsShown)
                .animation(.easeInOut(duration: 0.2), value: state.controlsShown)
        }
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
    }
}
