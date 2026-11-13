//
//  WindowBanner.swift
//  Greenroom
//
//  Every message Greenroom shows - a toast, the upload question, the start's
//  "Getting ready" card - lives in one place: a floating glass panel at the
//  top-right of the screen the person is working on, where macOS shows its
//  own notifications. Never inside a Greenroom window, so a message can never
//  sit on Start Meeting or any other control.
//
//  ToastController, UploadPromptCard and ReadinessHUDController keep their
//  APIs and hand their content to BannerCenter. This file is the one panel
//  that draws it, and the pure frame math that places it.
//
import SwiftUI
import AppKit
import Combine

@MainActor
final class BannerCenter: ObservableObject {
    static let shared = BannerCenter()

    private init() {
        // After init returns, so the panel can look this object up.
        DispatchQueue.main.async { BannerPanelController.shared.start() }
    }

    struct ToastItem: Equatable {
        var title: String
        var detail: String?
        var kind: ToastController.Kind
    }

    struct PromptItem: Equatable {
        var title: String
        var detail: String
        var uploadTitle: String = "Upload"
    }

    @Published private(set) var toast: ToastItem?
    @Published private(set) var prompt: PromptItem?
    @Published private(set) var readiness: ParticipantGridWindowController.Readiness?

    var isShowing: Bool { toast != nil || prompt != nil || readiness != nil }
    /// Something with a button: the panel takes clicks only then.
    var isInteractive: Bool { prompt != nil || readiness?.failure != nil }

    private var toastTask: Task<Void, Never>?
    private var readinessTask: Task<Void, Never>?

    func showToast(_ item: ToastItem, dismissAfter: TimeInterval?) {
        toastTask?.cancel()
        toastTask = nil
        withAnimation(.easeOut(duration: 0.25)) { toast = item }
        guard let dismissAfter else { return }
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(dismissAfter * 1_000_000_000))
            guard !Task.isCancelled else { return }
            hideToast()
        }
    }

    func hideToast() {
        toastTask?.cancel()
        toastTask = nil
        guard toast != nil else { return }
        withAnimation(.easeIn(duration: 0.25)) { toast = nil }
    }

    func showPrompt(_ item: PromptItem) {
        withAnimation(.easeOut(duration: 0.25)) { prompt = item }
    }

    func hidePrompt() {
        guard prompt != nil else { return }
        withAnimation(.easeIn(duration: 0.25)) { prompt = nil }
    }

    func showReadiness(_ value: ParticipantGridWindowController.Readiness) {
        // Nothing left to report. A failure stays; otherwise a beat on the
        // ticked list before it goes, as the floating card does.
        guard !value.steps.isEmpty || value.failure != nil else {
            guard readiness != nil, readinessTask == nil else { return }
            readinessTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard !Task.isCancelled else { return }
                hideReadiness()
            }
            return
        }
        readinessTask?.cancel()
        readinessTask = nil
        if readiness == nil {
            withAnimation(.easeOut(duration: 0.25)) { readiness = value }
        } else {
            readiness = value
        }
    }

    func hideReadiness() {
        readinessTask?.cancel()
        readinessTask = nil
        guard readiness != nil else { return }
        withAnimation(.easeIn(duration: 0.25)) { readiness = nil }
    }
}

/// Kept so a leftover `.overlay { WindowBannerOverlay() }` compiles; messages
/// never draw inside a window any more.
struct WindowBannerOverlay: View {
    var body: some View { EmptyView() }
}

private struct StackSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// What the panel draws: prompt, readiness, toast, top to bottom.
private struct BannerStackView: View {
    @ObservedObject var banners: BannerCenter
    let onSize: (CGSize) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var transition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: BannerLayout.gap) {
            if let prompt = banners.prompt {
                PromptBanner(item: prompt).transition(transition)
            }
            if let readiness = banners.readiness {
                ReadinessBanner(readiness: readiness).transition(transition)
            }
            if let toast = banners.toast {
                ToastBanner(item: toast).transition(transition)
            }
        }
        .frame(width: BannerLayout.cardWidth)
        .padding(BannerLayout.shadowPad)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: StackSizeKey.self, value: proxy.size)
        })
        .onPreferenceChange(StackSizeKey.self) { onSize($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}

/// The one panel. Non-activating, on every Space and over full-screen apps,
/// above normal windows and below system alerts.
@MainActor
final class BannerPanelController {
    static let shared = BannerPanelController()

    private final class MessagePanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private var panel: MessagePanel?
    private var screen: NSScreen?
    private var stack: CGSize = .zero
    private var shrinkTask: Task<Void, Never>?
    private var tracking: AnyCancellable?

    /// The panel's current frame, for the debug tour.
    var frame: NSRect? { panel?.isVisible == true ? panel?.frame : nil }
    var windowNumber: Int? { panel?.windowNumber }

    func start() {
        guard tracking == nil else { return }
        let banners = BannerCenter.shared
        // Make the panel the moment something is showing, so its content
        // can measure itself and report the size.
        tracking = banners.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.ensurePanel() }
        }
    }

    /// The screen the person is working on: the one under the pointer.
    private static func workingScreen() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func ensurePanel() {
        let banners = BannerCenter.shared
        guard banners.isShowing else {
            scheduleHide()
            return
        }
        shrinkTask?.cancel()
        shrinkTask = nil
        if panel == nil {
            screen = Self.workingScreen()
            panel = makePanel()
        }
        panel?.ignoresMouseEvents = !banners.isInteractive
        place()
        panel?.orderFrontRegardless()
    }

    private func makePanel() -> MessagePanel {
        let created = MessagePanel(contentRect: NSRect(x: 0, y: 0, width: BannerLayout.cardWidth, height: 80),
                                   styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        created.title = "Messages"
        created.isReleasedWhenClosed = false
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = false          // each card draws its own
        created.hidesOnDeactivate = false
        // Above normal windows, below modal panels and system alerts.
        created.level = .floating
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = NSHostingView(rootView: BannerStackView(banners: BannerCenter.shared) { [weak self] size in
            Task { @MainActor in self?.stackSizeChanged(size) }
        })
        created.contentView = host
        return created
    }

    private func stackSizeChanged(_ size: CGSize) {
        // The size includes the shadow padding already.
        let next = CGSize(width: size.width - BannerLayout.shadowPad * 2,
                          height: size.height - BannerLayout.shadowPad * 2)
        if next.height >= stack.height {
            stack = next
            place()
        } else {
            // Shrinking: let the card that is leaving finish its exit first.
            shrinkTask?.cancel()
            shrinkTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled, let self else { return }
                self.stack = next
                self.place()
            }
        }
    }

    private func place() {
        guard let panel, stack.height > 0 else { return }
        let visible = (screen ?? Self.workingScreen())?.visibleFrame ?? .zero
        let target = BannerLayout.panelFrame(stack: stack, in: visible)
        if panel.frame != target { panel.setFrame(target, display: true) }
    }

    private func scheduleHide() {
        guard panel != nil else { return }
        shrinkTask?.cancel()
        shrinkTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)     // after the exit slide
            guard !Task.isCancelled, let self, !BannerCenter.shared.isShowing else { return }
            self.panel?.orderOut(nil)
            self.panel?.close()
            self.panel = nil
            self.stack = .zero
        }
    }
}

/// The card surface all three share: Liquid Glass at radius-lg.
private struct BannerCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(14)
            .frame(width: BannerLayout.cardWidth, alignment: .leading)
            .greenroomGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
    }
}

private struct ToastBanner: View {
    let item: BannerCenter.ToastItem

    private var tint: Color {
        switch item.kind {
        case .working: return .secondary
        case .success: return Brand.green
        case .failure: return .red
        }
    }

    var body: some View {
        BannerCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: item.kind.symbol)
                    .foregroundStyle(tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    if let detail = item.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PromptBanner: View {
    let item: BannerCenter.PromptItem

    var body: some View {
        BannerCard {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 22))
                    // The upload leaves this Mac: amber, not green (DESIGN.md).
                    .foregroundStyle(Brand.net)
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(2)
                    Text(item.detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Spacer(minLength: 0)
                        Button("Not now") { UploadPromptCard.notNow() }
                        Button(item.uploadTitle) { UploadPromptCard.upload() }
                            .buttonStyle(.borderedProminent)
                            .tint(Brand.net)
                    }
                    .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The start's steps:
/// a bar, the named steps, the newest status line, and on a failure the
/// reason with its way out.
private struct ReadinessBanner: View {
    let readiness: ParticipantGridWindowController.Readiness

    var body: some View {
        BannerCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(readiness.failure == nil ? "GETTING READY" : "COULD NOT START")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.2))
                        // A fill, which is the one thing DESIGN.md allows the lime to be.
                        Capsule().fill(Brand.fill)
                            .frame(width: proxy.size.width * fraction)
                            .animation(.easeInOut(duration: 0.25), value: fraction)
                    }
                }
                .frame(height: 3)

                ForEach(Array(readiness.steps.enumerated()), id: \.offset) { _, step in
                    row(step)
                }

                if let failure = readiness.failure {
                    Text(failure)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Spacer(minLength: 0)
                        Button("Close") {
                            Task { @MainActor in ParticipantGridWindowController.readinessDismiss?() }
                        }
                        Button("Try again") {
                            Task { @MainActor in ParticipantGridWindowController.readinessTryAgain?() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if let detail = readiness.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var fraction: Double {
        readiness.steps.isEmpty ? 0 : Double(readiness.settled) / Double(readiness.steps.count)
    }

    private func row(_ step: ParticipantGridWindowController.Readiness.Step) -> some View {
        HStack(spacing: 8) {
            Group {
                switch step.state {
                case .pending:
                    Image(systemName: "circle").foregroundStyle(.secondary)
                case .active:
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.green)
                case .skipped:
                    Image(systemName: "minus.circle").foregroundStyle(.secondary)
                case .failed:
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                }
            }
            .frame(width: 16, height: 16)
            Text(step.label)
                .font(.system(size: 13))
                .foregroundStyle(style(step.state))
        }
    }

    private func style(_ state: ParticipantGridWindowController.Readiness.State) -> AnyShapeStyle {
        switch state {
        case .pending, .skipped: return AnyShapeStyle(.secondary)
        case .active: return AnyShapeStyle(.primary)
        case .done: return AnyShapeStyle(.secondary)
        case .failed: return AnyShapeStyle(Color.red)
        }
    }
}
