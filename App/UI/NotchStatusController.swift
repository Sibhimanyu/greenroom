//
//  NotchStatusController.swift
//
//  The start's status as a pill that grows out of the MacBook notch, in the
//  manner of Dynamic Island. On a display with a notch the pill is pure black,
//  flush with the top of the screen and centred on the notch, over the menu bar,
//  so it reads as the notch itself stretching. Without a notch (or on an
//  external display) the same pill drops from the top centre, just below the
//  menu bar, as a dark glass capsule. DESIGN.md, "Status pill".
//
//  Presentation only: readiness, its steps and its fix actions are unchanged.
//  The pure parts (state machine, step words, notch rectangle, placement) are
//  in NotchStatusRules.swift.
//
import SwiftUI
import AppKit

extension Notification.Name {
    /// The pill appeared, moved or left: other messages re-stack below it.
    static let notchStatusFrameChanged = Notification.Name("GreenroomNotchStatusFrameChanged")
}

@MainActor
final class NotchStatusModel: ObservableObject {
    @Published var phase: NotchPhase = .hidden
    /// Open (a pill) or folded into the notch (nothing to see).
    @Published var shown = false
    var notch: CGRect?
    var reduceMotion = false
    var onAction: (() -> Void)?
    var onDismiss: (() -> Void)?
}

@MainActor
final class NotchStatusController {
    static let shared = NotchStatusController()

    private final class StatusPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
        // The panel sits over the menu bar on purpose: keep our frame.
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private let model = NotchStatusModel()
    private var panel: StatusPanel?
    private var screen: NSScreen?
    private(set) var phase: NotchPhase = .hidden
    /// How long "Live" holds. The debug tour lengthens it to take a picture.
    var liveHold: TimeInterval = NotchStatusRules.liveHold
    private var holdTask: Task<Void, Never>?
    private var teardownTask: Task<Void, Never>?

    // MARK: Readiness in

    /// Feed the readiness reading. `onAction` is the fix button (Try again),
    /// `onDismiss` the cross.
    func update(_ input: NotchInput, onAction: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        model.onAction = onAction
        model.onDismiss = onDismiss
        let next = NotchStatusRules.next(from: phase, input: input)
        guard next != phase else { return }
        let was = phase
        phase = next
        holdTask?.cancel()
        holdTask = nil
        switch next {
        case .hidden:
            if was != .hidden { collapse() }
        case .working, .failed:
            present(next)
        case .live:
            present(next)
            holdTask = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(self.liveHold * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.phase = .hidden
                self.collapse()
            }
        }
    }

    /// Fold away now, whatever it was showing.
    func clear() {
        holdTask?.cancel()
        holdTask = nil
        guard phase != .hidden || panel != nil else { return }
        phase = .hidden
        collapse()
    }

    // MARK: Presenting

    private var animation: Animation {
        model.reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.8)
    }

    private func present(_ next: NotchPhase) {
        teardownTask?.cancel()
        teardownTask = nil
        model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let opening = panel == nil
        if opening {
            let target = BannerPanelController.workingScreen()
            screen = target
            model.notch = Self.notchRect(of: target)
            model.shown = false
            model.phase = next
            panel = makePanel()
        }
        panel?.ignoresMouseEvents = !next.isFailure
        panel?.orderFrontRegardless()
        if opening || !model.shown {
            // One turn of the run loop in the folded state, so the morph has a start.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.phase != .hidden else { return }
                withAnimation(self.animation) {
                    self.model.phase = self.phase
                    self.model.shown = true
                }
                self.postFrameChange()
            }
        } else {
            withAnimation(animation) { model.phase = next }
            postFrameChange()
        }
    }

    private func collapse() {
        withAnimation(animation) { model.shown = false }
        postFrameChange()
        teardownTask?.cancel()
        teardownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 550_000_000)
            guard !Task.isCancelled, let self, self.phase == .hidden else { return }
            self.panel?.orderOut(nil)
            self.panel?.close()
            self.panel = nil
            self.model.phase = .hidden
            self.postFrameChange()
        }
    }

    private func makePanel() -> StatusPanel {
        let frame = NotchGeometry.panelFrame(screenFrame: screen?.frame ?? .zero,
                                             visibleFrame: screen?.visibleFrame ?? .zero,
                                             notch: model.notch)
        let created = StatusPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        created.title = "Status"
        created.isReleasedWhenClosed = false
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = false
        created.hidesOnDeactivate = false
        // Above the menu bar, so the pill can cover the notch's strip of it.
        created.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        created.ignoresMouseEvents = true
        let host = NSHostingView(rootView: NotchPillView(model: model))
        host.sizingOptions = []
        created.contentView = host
        created.setFrame(frame, display: false)
        return created
    }

    private func postFrameChange() {
        NotificationCenter.default.post(name: .notchStatusFrameChanged, object: nil)
    }

    // MARK: Reads

    static func notchRect(of screen: NSScreen?) -> CGRect? {
        guard let screen else { return nil }
        return NotchGeometry.notchRect(screenFrame: screen.frame,
                                       safeAreaTop: screen.safeAreaInsets.top,
                                       leftArea: screen.auxiliaryTopLeftArea,
                                       rightArea: screen.auxiliaryTopRightArea)
    }

    /// The pill's frame while it is open, so other messages stack below it.
    func occupiedFrame(on other: NSScreen?) -> CGRect? {
        guard let panel, model.shown, phase != .hidden, screen === other else { return nil }
        return NotchGeometry.pillFrame(panel: panel.frame, notch: model.notch, phase: phase)
    }

    /// For the debug tour.
    var debugPanel: NSPanel? { panel }
    var debugNotch: CGRect? { model.notch }
}

// MARK: - The pill

private struct NotchPillView: View {
    @ObservedObject var model: NotchStatusModel

    private var notchHeight: CGFloat { model.notch?.height ?? 0 }
    private var hasNotch: Bool { model.notch != nil }
    private var failed: Bool { model.phase.isFailure }

    private var openSize: CGSize {
        CGSize(width: NotchGeometry.width(for: model.phase), height: notchHeight + NotchGeometry.bodyHeight)
    }

    /// Folded: exactly the notch, or (no notch, or Reduce Motion) the open size
    /// with the fade doing the work.
    private var size: CGSize {
        if model.shown || model.reduceMotion { return openSize }
        if let notch = model.notch { return CGSize(width: notch.width, height: notch.height) }
        return openSize
    }

    private var shapeOpacity: Double {
        if model.shown { return 1 }
        return hasNotch && !model.reduceMotion ? 1 : 0
    }

    var body: some View {
        pill
            .frame(width: NotchGeometry.failureWidth, height: notchHeight + NotchGeometry.bodyHeight,
                   alignment: .top)
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var pill: some View {
        let dropped = !model.shown && !hasNotch && !model.reduceMotion
        let content = VStack(spacing: 0) {
            if hasNotch { Color.clear.frame(height: notchHeight) }
            row.frame(height: NotchGeometry.bodyHeight)
        }
        .padding(.horizontal, 16)
        .frame(width: size.width, height: size.height, alignment: .top)
        .opacity(model.shown ? 1 : 0)
        .animation(model.reduceMotion ? .easeInOut(duration: 0.2)
                   : .easeOut(duration: 0.18).delay(model.shown ? 0.1 : 0), value: model.shown)

        if hasNotch {
            let shape = UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22, style: .continuous)
            content
                .background {
                    // Always one black island, like Dynamic Island: a failure
                    // speaks through its amber icon, text and button, not a
                    // second-coloured band (owner, 2026-11-14).
                    shape.fill(Color.black)
                }
                .clipShape(shape)
                .opacity(shapeOpacity)
        } else {
            content
                .background {
                    ZStack {
                        Capsule().fill(Color.black.opacity(0.55))
                        if failed { Capsule().fill(Brand.net.opacity(0.2)) }
                    }
                }
                .greenroomGlass(in: Capsule())
                .overlay { if failed { Capsule().strokeBorder(Brand.net.opacity(0.7), lineWidth: 1) } }
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                .opacity(shapeOpacity)
                .offset(y: dropped ? -14 : 0)
        }
    }

    // MARK: Body row

    @ViewBuilder
    private var row: some View {
        switch model.phase {
        case .hidden:
            Color.clear
        case .working(let progress):
            HStack(spacing: 10) {
                mark
                ZStack(alignment: .leading) {
                    Text(progress.text)
                        .id(progress.text)
                        .transition(.opacity)
                }
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                NotchRing(progress: progress, reduceMotion: model.reduceMotion)
            }
            .help(progress.detail ?? "")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Getting ready. \(progress.text) \(progress.counter)")
        case .live(let recording):
            HStack(spacing: 10) {
                mark
                HStack(spacing: 6) {
                    Circle().fill(recording ? Color.red : Brand.green).frame(width: 8, height: 8)
                    Text(NotchStatusRules.liveText(recording: recording))
                        .font(.system(size: 13, weight: .medium))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(NotchStatusRules.liveText(recording: recording))
        case .failed(let failure):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.net)
                Text(failure.message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Brand.netText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { model.onAction?() } label: {
                    Text("Try again")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Brand.net, in: Capsule())
                }
                .buttonStyle(.plain)
                Button { model.onDismiss?() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .help([failure.message, failure.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
        }
    }

    private var mark: some View {
        Image("MenuBarMark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(height: 16)
            .foregroundStyle(Color.white)
    }
}

/// The progress ring: the share of steps settled, "3/5" inside, and a quick
/// check-tick whenever a step finishes.
private struct NotchRing: View {
    let progress: NotchProgress
    let reduceMotion: Bool
    @State private var ticking = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: 2.5)
            Circle().trim(from: 0, to: progress.fraction)
                .stroke(Brand.fill, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if ticking {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Brand.fill)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
            } else {
                Text(progress.counter)
                    .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.85))
                    .minimumScaleFactor(0.7)
                    .transition(.opacity)
            }
        }
        .frame(width: 30, height: 30)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.8),
                   value: ticking)
        .animation(.easeOut(duration: 0.25), value: progress.fraction)
        .onChange(of: progress.settled) { old, new in
            guard new > old else { return }
            ticking = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 650_000_000)
                ticking = false
            }
        }
    }
}
