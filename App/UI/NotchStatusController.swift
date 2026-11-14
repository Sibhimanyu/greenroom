//
//  NotchStatusController.swift
//
//  The island: one black pill that grows out of the MacBook notch, in the
//  manner of Dynamic Island, and carries every message Greenroom has. On a
//  display with a notch it is pure black, flush with the top of the screen and
//  centred on the notch, over the menu bar, so it reads as the notch itself
//  stretching. Without a notch (or on an external display) the same pill drops
//  from the top centre, just below the menu bar, as a dark glass capsule.
//  DESIGN.md, "Status pill" and "Messages".
//
//  It shows one thing at a time (rules in IslandQueue, NotchStatusRules.swift):
//  a failure, then the recording countdown, then the start's status, then the
//  FIFO of upload prompts and toasts. Between two queued messages it retracts.
//
//  Presentation only: readiness, its steps and its fix actions are unchanged.
//
import SwiftUI
import AppKit

@MainActor
final class NotchStatusModel: ObservableObject {
    @Published var content: IslandContent = .none
    /// Open (a pill) or folded into the notch (nothing to see).
    @Published var shown = false
    var notch: CGRect?
    var reduceMotion = false
    var onAction: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onCancelCountdown: (() -> Void)?
    var onUpload: ((UUID) -> Void)?
    var onNotNow: ((UUID) -> Void)?
    var onToastTap: ((UUID) -> Void)?
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

    private struct PromptHandlers {
        var onUpload: () -> Void
        var onDismiss: () -> Void
    }

    private let model = NotchStatusModel()
    private var panel: StatusPanel?
    private var screen: NSScreen?
    private var queue = IslandQueue()
    var phase: NotchPhase { queue.status }
    /// How long "Live" holds. The debug tour lengthens it to take a picture.
    var liveHold: TimeInterval = NotchStatusRules.liveHold
    private var holdTask: Task<Void, Never>?
    private var teardownTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var timerFor: UUID?
    private var goTask: Task<Void, Never>?
    private var retractTask: Task<Void, Never>?
    private var retracting = false
    private var prompts: [UUID: PromptHandlers] = [:]
    private var toastActions: [UUID: () -> Void] = [:]
    private var escMonitors: [Any] = []

    init() {
        model.onCancelCountdown = { [weak self] in self?.cancelCountdown() }
        model.onUpload = { [weak self] id in self?.answerPrompt(id, upload: true) }
        model.onNotNow = { [weak self] id in self?.answerPrompt(id, upload: false) }
        model.onToastTap = { [weak self] id in self?.tapToast(id) }
    }

    // MARK: Readiness in

    /// Feed the readiness reading. `onAction` is the fix button (Try again),
    /// `onDismiss` the cross.
    func update(_ input: NotchInput, onAction: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        model.onAction = onAction
        model.onDismiss = onDismiss
        let next = NotchStatusRules.next(from: phase, input: input)
        guard next != phase else { return }
        queue.setStatus(next)
        holdTask?.cancel()
        holdTask = nil
        if case .live = next {
            holdTask = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(self.liveHold * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.queue.setStatus(.hidden)
                self.refresh()
            }
        }
        refresh()
    }

    /// Fold the start's status away now, whatever it was showing.
    func clear() {
        holdTask?.cancel()
        holdTask = nil
        guard !queue.status.isHidden else { return }
        queue.setStatus(.hidden)
        refresh()
    }

    // MARK: Countdown in

    /// The recording countdown reads `value`; nil means it ended. A countdown
    /// that reached go keeps its "Recording" beat; one that did not just goes.
    func setCountdown(_ value: Int?, onCancel: (() -> Void)? = nil) {
        if let value {
            goTask?.cancel()
            goTask = nil
            pendingCancel = onCancel ?? pendingCancel
            queue.setCountdown(.tick(value))
            installMonitors()
        } else {
            removeMonitors()
            guard queue.countdown != .go else { return }
            pendingCancel = nil
            queue.setCountdown(nil)
        }
        refresh()
    }

    private var pendingCancel: (() -> Void)?

    /// The countdown reached zero: "Recording" for a second, then the island retracts.
    func countdownGo() {
        removeMonitors()
        pendingCancel = nil
        queue.setCountdown(.go)
        goTask?.cancel()
        goTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(IslandRules.goHold * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.queue.setCountdown(nil)
            self.refresh()
        }
        refresh()
    }

    private func cancelCountdown() {
        pendingCancel?()
    }

    /// Esc cancels. A local monitor hears it while Greenroom is in front; a
    /// global one while another app is (it needs Accessibility, like the
    /// events tracker; without it the Cancel button and the start shortcut
    /// still work).
    private func installMonitors() {
        guard escMonitors.isEmpty else { return }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.cancelCountdown()
            return nil
        }) { escMonitors.append(local) }
        if AXIsProcessTrusted(),
           let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
               guard event.keyCode == 53 else { return }
               MainActor.assumeIsolated { self?.cancelCountdown() }
           }) { escMonitors.append(global) }
    }

    private func removeMonitors() {
        for monitor in escMonitors { NSEvent.removeMonitor(monitor) }
        escMonitors = []
    }

    // MARK: Messages in

    func showToast(_ toast: IslandToast, action: (() -> Void)? = nil) {
        if let action { toastActions[toast.id] = action }
        enqueue(.toast(toast))
    }

    /// Takes every toast, showing or waiting, off the island.
    func hideToasts() {
        let gone = queue.remove { if case .toast = $0 { return true } else { return false } }
        for m in gone { toastActions[m.id] = nil }
        afterRemoval(gone)
    }

    func showPrompt(_ prompt: IslandPrompt, onUpload: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        prompts[prompt.id] = PromptHandlers(onUpload: onUpload, onDismiss: onDismiss)
        enqueue(.prompt(prompt))
    }

    /// A question the person just asked for (End): shown at once, ahead of
    /// anything waiting. `onConfirm` runs on the red button only; the other
    /// button, a timeout and being taken away all run `onDismiss`.
    func showConfirm(_ prompt: IslandPrompt, onConfirm: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        prompts[prompt.id] = PromptHandlers(onUpload: onConfirm, onDismiss: onDismiss)
        queue.enqueueFirst(.prompt(prompt))
        refresh()
    }

    /// Takes one prompt away; `answered` false runs its dismiss handler.
    func hidePrompt(_ id: UUID, answered: Bool) {
        let gone = queue.remove { $0.id == id }
        let handler = prompts.removeValue(forKey: id)
        afterRemoval(gone)
        if !answered { handler?.onDismiss() }
    }

    /// Takes every upload prompt away. `answered` false runs their dismiss handlers.
    func hidePrompts(answered: Bool) {
        let gone = queue.remove { if case .prompt = $0 { return true } else { return false } }
        let handlers = gone.compactMap { prompts.removeValue(forKey: $0.id) }
        afterRemoval(gone)
        if !answered { for h in handlers { h.onDismiss() } }
    }

    /// Everything but the start's status, for the debug tour's restore.
    func clearAll() {
        hideToasts()
        hidePrompts(answered: true)
        goTask?.cancel()
        goTask = nil
        removeMonitors()
        pendingCancel = nil
        queue.setCountdown(nil)
        clear()
        refresh()
    }

    private func answerPrompt(_ id: UUID, upload: Bool) {
        guard queue.finish(id) else { return }
        let handlers = prompts.removeValue(forKey: id)
        afterFinish()
        if upload { handlers?.onUpload() } else { handlers?.onDismiss() }
    }

    private func tapToast(_ id: UUID) {
        guard queue.finish(id) else { return }
        let action = toastActions.removeValue(forKey: id)
        afterFinish()
        action?()
    }

    private func finishByTimer(_ id: UUID) {
        guard queue.finish(id) else { return }
        toastActions[id] = nil
        let handlers = prompts.removeValue(forKey: id)
        afterFinish()
        handlers?.onDismiss()
    }

    private func enqueue(_ message: IslandMessage) {
        queue.enqueue(message)
        if !retracting { queue.promote() }
        refresh()
    }

    private func afterRemoval(_ gone: [IslandMessage]) {
        guard !gone.isEmpty else { return }
        queue.promote()
        refresh()
    }

    /// A message left: the island retracts a beat before the next one opens.
    private func afterFinish() {
        retracting = true
        retractTask?.cancel()
        retractTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(IslandRules.retractGap * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.retracting = false
            self.queue.promote()
            self.refresh()
        }
        refresh()
    }

    // MARK: Presenting

    private var animation: Animation {
        model.reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.8)
    }

    /// Bring the island in line with the queue: its timer, its size, its shape.
    private func refresh() {
        let content = queue.content
        if content.messageID != timerFor {
            messageTask?.cancel()
            messageTask = nil
            timerFor = content.messageID
            if let id = timerFor {
                var seconds: TimeInterval?
                switch content {
                case .toast(let t): seconds = t.duration
                case .prompt(let p): seconds = p.timeout
                default: break
                }
                if let seconds {
                    messageTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                        guard !Task.isCancelled else { return }
                        self?.finishByTimer(id)
                    }
                }
            }
        }
        if content.isNone {
            if panel != nil { collapse() }
        } else {
            present(content)
        }
    }

    private func present(_ content: IslandContent) {
        teardownTask?.cancel()
        teardownTask = nil
        model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let opening = panel == nil
        if opening {
            let target = Self.workingScreen()
            screen = target
            model.notch = Self.notchRect(of: target)
            model.shown = false
            model.content = content
            panel = makePanel()
        }
        panel?.ignoresMouseEvents = !content.isInteractive
        panel?.orderFrontRegardless()
        if opening || !model.shown {
            // One turn of the run loop in the folded state, so the morph has a start.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.queue.content.isNone else { return }
                withAnimation(self.animation) {
                    self.model.content = self.queue.content
                    self.model.shown = true
                }
                self.panel?.ignoresMouseEvents = !self.queue.content.isInteractive
            }
        } else {
            withAnimation(animation) { model.content = content }
        }
    }

    private func collapse() {
        withAnimation(animation) { model.shown = false }
        teardownTask?.cancel()
        teardownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 550_000_000)
            guard !Task.isCancelled, let self, self.queue.content.isNone else { return }
            self.panel?.orderOut(nil)
            self.panel?.close()
            self.panel = nil
            self.model.content = .none
        }
    }

    /// The screen the person is working on: the one under the pointer.
    static func workingScreen() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
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

    // MARK: Reads

    static func notchRect(of screen: NSScreen?) -> CGRect? {
        guard let screen else { return nil }
        return NotchGeometry.notchRect(screenFrame: screen.frame,
                                       safeAreaTop: screen.safeAreaInsets.top,
                                       leftArea: screen.auxiliaryTopLeftArea,
                                       rightArea: screen.auxiliaryTopRightArea)
    }

    /// For the debug tour.
    var debugPanel: NSPanel? { panel }
    var debugNotch: CGRect? { model.notch }
    var debugContent: IslandContent { queue.content }
}

// MARK: - The pill

private struct NotchPillView: View {
    @ObservedObject var model: NotchStatusModel

    private var notchHeight: CGFloat { model.notch?.height ?? 0 }
    private var hasNotch: Bool { model.notch != nil }
    private var failed: Bool { if case .status(let p) = model.content { return p.isFailure } else { return false } }

    private var openSize: CGSize {
        let body = NotchGeometry.bodySize(for: model.content)
        return CGSize(width: body.width, height: notchHeight + body.height)
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
            .frame(width: NotchGeometry.panelWidth, height: notchHeight + NotchGeometry.panelBodyHeight,
                   alignment: .top)
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var pill: some View {
        let dropped = !model.shown && !hasNotch && !model.reduceMotion
        let content = VStack(spacing: 0) {
            if hasNotch { Color.clear.frame(height: notchHeight) }
            row
                .id(rowKind)
                .transition(.opacity)
                .frame(height: NotchGeometry.bodySize(for: model.content).height)
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

    /// Changes when the row is another kind of thing, so the swap cross-fades.
    private var rowKind: String {
        switch model.content {
        case .none: return "none"
        case .status(let p):
            switch p {
            case .hidden: return "hidden"
            case .working: return "working"
            case .live: return "live"
            case .failed: return "failed"
            }
        case .countdown(let c): return c == .go ? "go" : "countdown"
        case .toast(let t): return "toast"  + t.id.uuidString
        case .prompt(let p): return "prompt" + p.id.uuidString
        }
    }

    // MARK: Body row

    @ViewBuilder
    private var row: some View {
        switch model.content {
        case .none, .status(.hidden):
            Color.clear
        case .countdown(let phase):
            countdownRow(phase)
        case .toast(let toast):
            toastRow(toast)
        case .prompt(let prompt):
            promptRow(prompt)
        case .status(let phase):
            statusRow(phase)
        }
    }

    @ViewBuilder
    private func statusRow(_ phase: NotchPhase) -> some View {
        switch phase {
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

    // MARK: Countdown, toast, upload prompt

    @ViewBuilder
    private func countdownRow(_ phase: CountdownPhase) -> some View {
        switch phase {
        case .tick(let n):
            HStack(spacing: 12) {
                ZStack {
                    Text("\(n)")
                        .id(n)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .transition(model.reduceMotion ? .opacity : .scale(scale: 0.3).combined(with: .opacity))
                }
                .frame(width: 44, height: 44)
                .animation(model.reduceMotion ? .easeInOut(duration: 0.2)
                           : .spring(response: 0.35, dampingFraction: 0.6), value: n)
                Text("Recording starts")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { model.onCancelCountdown?() } label: {
                    Text("Cancel")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.white.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Stop the countdown. Nothing is recorded. (Esc)")
                .accessibilityLabel("Cancel recording")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Recording starts in \(n)")
        case .go:
            HStack(spacing: 8) {
                Circle().fill(Color.red).frame(width: 9, height: 9)
                Text("Recording")
                    .font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recording")
        }
    }

    private func toastRow(_ toast: IslandToast) -> some View {
        let tint: Color = {
            switch toast.kind {
            case .working: return Color.white.opacity(0.7)
            case .success: return Brand.green
            case .failure: return Brand.net
            }
        }()
        return HStack(spacing: 10) {
            Image(systemName: toast.kind.symbol)
                .font(.system(size: 14))
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(toast.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(toast.kind == .failure ? Brand.netText : Color.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if toast.hasDetail, let detail = toast.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture { if toast.hasAction { model.onToastTap?(toast.id) } }
        .help([toast.title, toast.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
        .accessibilityElement(children: .combine)
    }

    private func promptRow(_ prompt: IslandPrompt) -> some View {
        // The upload leaves this Mac: amber, not green (DESIGN.md). A confirm
        // ends something for other people: red, like Zoom's End.
        let confirm = prompt.style == .confirm
        let tint: Color = confirm ? Color(nsColor: .systemRed) : Brand.net
        return HStack(spacing: 12) {
            Image(systemName: confirm ? "phone.down.fill" : "play.rectangle.fill")
                .font(.system(size: confirm ? 22 : 26))
                .foregroundStyle(tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(prompt.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(prompt.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(confirm ? 2 : 1)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: confirm)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.onNotNow?(prompt.id) } label: {
                Text(prompt.dismissTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Color.white.opacity(0.14), in: Capsule())
            }
            .buttonStyle(.plain)
            Button { model.onUpload?(prompt.id) } label: {
                Text(prompt.uploadTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(confirm ? Color.white : Color.black)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(tint, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .help(prompt.help ?? "")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(prompt.title) \(prompt.detail)")
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
