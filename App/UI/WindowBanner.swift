//
//  WindowBanner.swift
//  Greenroom
//
//  Every message Greenroom shows - a toast, the upload question - lives in one
//  place: a floating glass panel at the
//  top-centre of the screen the person is working on, just below the menu bar. Never inside a Greenroom window, so a message can never
//  sit on Start Meeting or any other control.
//
//  ToastController and UploadPromptCard keep their APIs and hand their content
//  to BannerCenter. The start's status is not here: it is the pill that grows
//  out of the notch (NotchStatusController.swift), and these stack below it. This file is the one panel
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

    var isShowing: Bool { toast != nil || prompt != nil }
    /// Something with a button: the panel takes clicks only then.
    var isInteractive: Bool { prompt != nil }

    private var toastTask: Task<Void, Never>?

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

/// What the panel draws: prompt, toast, top to bottom.
private struct BannerStackView: View {
    @ObservedObject var banners: BannerCenter
    let onSize: (CGSize) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var transition: AnyTransition {
        reduceMotion ? .opacity : .offset(y: -10).combined(with: .opacity)
    }

    var body: some View {
        VStack(alignment: .center, spacing: BannerLayout.gap) {
            if let prompt = banners.prompt {
                PromptBanner(item: prompt).transition(transition)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        // AppKit pushes a window's top edge below the menu bar. The panel's top
        // edge is its shadow room, 2pt above the card's inset, so keep our frame.
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private var panel: MessagePanel?
    private var host: NSHostingView<BannerStackView>?
    private var screen: NSScreen?
    private var stack: CGSize = .zero
    private var shrinkTask: Task<Void, Never>?
    private var refitTask: Task<Void, Never>?
    private var tracking: AnyCancellable?
    private var pillObserver: NSObjectProtocol?

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
        // The status pill opened or left: re-stack below it.
        pillObserver = NotificationCenter.default.addObserver(forName: .notchStatusFrameChanged, object: nil,
                                                              queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        // BannerCenter is created lazily by the first message, so that
        // message's change fired before this sink existed: catch up now.
        ensurePanel()
    }

    /// The screen the person is working on: the one under the pointer.
    static func workingScreen() -> NSScreen? {
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
        refit()
        panel?.orderFrontRegardless()
        // SwiftUI finishes laying a new card out a beat later: measure again.
        refitTask?.cancel()
        refitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            self?.refit()
        }
    }

    /// Measure the stack straight from the hosting view and place the panel. The
    /// preference callback alone is not enough: in a panel that has just been made
    /// it can report only the first, empty size and then stay silent.
    private func refit() {
        guard let host else { return }
        host.layoutSubtreeIfNeeded()
        stackSizeChanged(host.fittingSize)
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
        // Intrinsic size only, so fittingSize measures the stack; the window's
        // own size is ours, set by place() from that measurement.
        host.sizingOptions = [.intrinsicContentSize]
        created.contentView = host
        self.host = host
        return created
    }

    private func stackSizeChanged(_ size: CGSize) {
        // Zero is the hosting view's first, not yet laid out report.
        guard size.width > BannerLayout.shadowPad * 2, size.height > BannerLayout.shadowPad * 2 else { return }
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
        let target_screen = screen ?? Self.workingScreen()
        // The status pill, when open, is the topmost thing: stack below it.
        let visible = BannerLayout.clearing(target_screen?.visibleFrame ?? .zero,
                                            pill: NotchStatusController.shared.occupiedFrame(on: target_screen))
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
            self.host = nil
            self.stack = .zero
        }
    }
}

/// The card surface both share: Liquid Glass at radius-lg.
private struct BannerCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(12)
            .frame(width: BannerLayout.cardWidth, alignment: .leading)
            .greenroomGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.kind.symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                    if let detail = item.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.subheadline)
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
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 20))
                    .frame(width: 24)
                    // The upload leaves this Mac: amber, not green (DESIGN.md).
                    .foregroundStyle(Brand.net)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                    Text(item.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        Button("Not now") { UploadPromptCard.notNow() }
                        Button(item.uploadTitle) { UploadPromptCard.upload() }
                            .buttonStyle(.borderedProminent)
                            .tint(Brand.net)
                    }
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
