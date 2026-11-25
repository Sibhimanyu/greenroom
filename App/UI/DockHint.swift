//
//  DockHint.swift
//  Greenroom
//
//  The hover card on Home's dock (owner, 2026-11-16: "when hovering the
//  explanation could be better with a small visual"). In place of the plain
//  yellow tooltip, a small glass card over the button: a little picture of
//  what the setting does, its name and current value, and one line.
//
//  The card is its own borderless panel, so it can sit above the window's
//  edge, never takes the mouse or the keyboard, and goes the moment the
//  pointer leaves, a click lands, or a key is pressed. Like a tooltip, the
//  first one waits a moment; moving along the dock swaps it at once.
//
import AppKit
import SwiftUI

/// What one dock button's card says and shows.
struct DockHintContent {
    var title: String
    var value: String
    var text: String
    var warn = false
    var visual: AnyView
}

extension View {
    /// Shows `hint` in a card over this view while the pointer rests on it.
    /// VoiceOver reads the line as the control's hint.
    func dockHint(_ hint: DockHintContent) -> some View {
        modifier(DockHintModifier(hint: hint))
    }
}

private struct DockHintModifier: ViewModifier {
    let hint: DockHintContent
    @State private var anchor = DockHintAnchor.Box()

    func body(content: Content) -> some View {
        content
            .background(DockHintAnchor(box: anchor))
            .onHover { inside in
                if inside { DockHintPanel.shared.hover(hint, over: anchor.view) }
                else { DockHintPanel.shared.leave(anchor.view) }
            }
            .onDisappear { DockHintPanel.shared.leave(anchor.view) }
            .accessibilityHint(hint.text)
    }
}

/// Finds the button's place on screen.
private struct DockHintAnchor: NSViewRepresentable {
    final class Box { weak var view: NSView? }
    let box: Box

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { box.view = view }
}

/// The one card, shared by every button.
@MainActor final class DockHintPanel {
    static let shared = DockHintPanel()

    private var panel: NSPanel?
    private var host: NSHostingView<DockHintCard>?
    private weak var owner: NSView?
    private var pending: DispatchWorkItem?
    private var monitor: Any?
    /// Shown recently: the next button shows its card without the wait.
    private var warmUntil = Date.distantPast
    /// A click or key put the card away; it stays away until the pointer
    /// comes to a button again.
    private var suppressed = false

    private static let delay: TimeInterval = 0.45

    /// True while the launch splash frosts the window: no card may open over
    /// it, and one already open is put away.
    var splashUp = false {
        didSet { if splashUp { hide() } }
    }

    func hover(_ hint: DockHintContent, over view: NSView?) {
        guard let view, !splashUp else { return }
        pending?.cancel()
        if owner !== view { suppressed = false }
        owner = view
        guard !suppressed else { return }
        let show = DispatchWorkItem { [weak self, weak view] in
            guard let self, let view, self.owner === view else { return }
            self.show(hint, over: view)
        }
        pending = show
        let wait = Date() < warmUntil || panel?.isVisible == true ? 0 : Self.delay
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: show)
    }

    func leave(_ view: NSView?) {
        guard view == nil || owner === view else { return }
        pending?.cancel()
        owner = nil
        // A short grace, so sliding to the next button does not flicker.
        let hide = DispatchWorkItem { [weak self] in
            guard let self, self.owner == nil else { return }
            self.hide()
        }
        pending = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: hide)
    }

    private func show(_ hint: DockHintContent, over view: NSView) {
        guard !splashUp, let window = view.window, window.isVisible, window.isKeyWindow || window.isMainWindow else { return }
        let panel = panel ?? makePanel()
        let card = DockHintCard(hint: hint)
        if let host { host.rootView = card } else {
            let host = NSHostingView(rootView: card)
            self.host = host
            panel.contentView = GreenroomGlassAppKit.makeBacking(cornerRadius: DockHintCard.radius, content: host)
        }
        panel.appearance = window.effectiveAppearance
        let size = host?.fittingSize ?? CGSize(width: DockHintCard.width, height: 160)

        // Over the button, centred on it, kept on the screen; under it when
        // there is no room above.
        let button = window.convertToScreen(view.convert(view.bounds, to: nil))
        let area = (window.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
        var origin = CGPoint(x: button.midX - size.width / 2, y: button.maxY + 6)
        if origin.y + size.height > area.maxY { origin.y = button.minY - 6 - size.height }
        origin.x = min(max(origin.x, area.minX + 8), area.maxX - 8 - size.width)
        panel.setFrame(CGRect(origin: origin, size: size).integral, display: true)

        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
                panel.animator().alphaValue = 1
            }
        }
        watch()
    }

    private func hide() {
        pending?.cancel()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard let panel, panel.isVisible else { return }
        warmUntil = Date().addingTimeInterval(0.6)
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// A click (which opens the button's menu) or a key puts the card away.
    private func watch() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            self?.suppressed = true
            self?.hide()
            return event
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        GreenroomGlassAppKit.prepare(panel)
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.setAccessibilityElement(false)
        self.panel = panel
        return panel
    }
}

/// The card: the picture, then the name with its value, then the line.
struct DockHintCard: View {
    static let width: CGFloat = 248
    static let radius: CGFloat = 14
    let hint: DockHintContent

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            hint.visual
                .frame(height: 104)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(hint.title)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 4)
                    Text(hint.value)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(hint.warn ? Brand.netText : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(hint.text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 2)
        }
        .padding(10)
        .frame(width: Self.width)
    }
}

// MARK: - The little pictures

/// Small drawings of what each dock setting does. Drawn, never captured: no
/// one's screen and no one's face.
enum DockHintVisual {
    /// The dark stage every picture is set on: what the class sees.
    static let stage = Color(red: 0.11, green: 0.12, blue: 0.14)

    /// A person, as a head and shoulders.
    struct Person: View {
        var tint: Color = .white.opacity(0.88)
        var body: some View {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    Circle().fill(tint)
                        .frame(width: w * 0.36, height: w * 0.36)
                        .position(x: w / 2, y: h * 0.36)
                    UnevenRoundedRectangle(topLeadingRadius: w * 0.3, topTrailingRadius: w * 0.3, style: .continuous)
                        .fill(tint)
                        .frame(width: w * 0.72, height: h * 0.34)
                        .position(x: w / 2, y: h * 0.86)
                }
            }
        }
    }

    /// A slide on the shared screen: a title bar and a few lines.
    struct Slide: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(.white.opacity(0.55)).frame(width: 64, height: 6)
                ForEach([110.0, 94, 120, 70], id: \.self) { width in
                    Capsule().fill(.white.opacity(0.22)).frame(maxWidth: width).frame(height: 4)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// A window: a title strip with three dots, and a body.
    struct Window: View {
        var lit = false
        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 2.5) {
                    ForEach(0..<3, id: \.self) { _ in Circle().fill(.white.opacity(0.35)).frame(width: 3.5, height: 3.5) }
                    Spacer()
                }
                .padding(.horizontal, 4)
                .frame(height: 9)
                .background(.white.opacity(lit ? 0.22 : 0.12))
                Rectangle().fill(.white.opacity(lit ? 0.14 : 0.06))
            }
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay {
                if lit {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(Brand.green, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
        }
    }

    /// You, in the corner, in the chosen shape.
    @ViewBuilder static func you(_ shape: WebcamShape, size: CGFloat = 40) -> some View {
        let tile = Brand.green.opacity(0.4)
        switch shape {
        case .circle:
            Person().padding(.top, size * 0.12).frame(width: size, height: size).background(tile).clipShape(Circle())
        case .square:
            Person().padding(.top, size * 0.12).frame(width: size, height: size).background(tile)
                .clipShape(RoundedRectangle(cornerRadius: 2))
        case .roundedRectangle:
            Person().padding(.top, size * 0.12).frame(width: size * 1.2, height: size).background(tile)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        case .cutout, .presenterLarge:
            Person().frame(width: size, height: size)
        }
    }

    /// Look: you over a slide, in the shape you picked.
    static func look(_ shape: WebcamShape, cameraOff: Bool) -> AnyView {
        AnyView(ZStack(alignment: .bottomTrailing) {
            stage
            if shape == .presenterLarge && !cameraOff {
                // The screen shrinks into a panel, you stand beside it.
                Slide()
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(0.06)))
                    .padding(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 76))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Person().frame(width: 64, height: 80).padding(.trailing, 6)
            } else {
                Slide()
                if !cameraOff { you(shape, size: 38).padding(9) }
            }
        })
    }

    /// Share: the thing behind you, outlined as the class will see it.
    static func share(_ kind: ShareTarget.Kind, shape: WebcamShape, cameraOff: Bool) -> AnyView {
        AnyView(ZStack(alignment: .bottomTrailing) {
            stage
            switch kind {
            case .display:
                ZStack(alignment: .topLeading) {
                    Window().frame(width: 96, height: 58).offset(x: 14, y: 14)
                    Window().frame(width: 84, height: 50).offset(x: 92, y: 34)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Brand.green, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
            case .app:
                ZStack(alignment: .topLeading) {
                    Window(lit: true).frame(width: 90, height: 54).offset(x: 14, y: 14)
                    Window(lit: true).frame(width: 78, height: 46).offset(x: 96, y: 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .window:
                ZStack(alignment: .topLeading) {
                    Window().frame(width: 80, height: 48).offset(x: 100, y: 12)
                    Window(lit: true).frame(width: 104, height: 62).offset(x: 14, y: 22)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .whiteboard:
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white.opacity(0.92))
                    .overlay(alignment: .topLeading) {
                        Path { p in
                            p.move(to: CGPoint(x: 16, y: 40))
                            p.addCurve(to: CGPoint(x: 92, y: 30), control1: CGPoint(x: 38, y: 12), control2: CGPoint(x: 64, y: 58))
                            p.move(to: CGPoint(x: 22, y: 64))
                            p.addLine(to: CGPoint(x: 112, y: 64))
                        }
                        .stroke(Color(red: 0.2, green: 0.25, blue: 0.3), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                    .padding(10)
            case .nothing:
                if !cameraOff {
                    you(shape == .cutout || shape == .presenterLarge ? .roundedRectangle : shape, size: 70)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if kind != .nothing && !cameraOff { you(shape, size: 34).padding(9) }
        })
    }

    /// Camera: the camera, and you on the class's screen.
    static func camera(off: Bool) -> AnyView {
        AnyView(ZStack {
            stage
            HStack(spacing: 10) {
                orb((off ? VisibilitySymbol.cameraOff : VisibilitySymbol.cameraOn).name)
                Flow()
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Brand.green.opacity(off ? 0.15 : 0.4))
                    if off {
                        Image(systemName: "person.slash").font(.system(size: 20)).foregroundStyle(.white.opacity(0.5))
                    } else {
                        Person().padding(.top, 10)
                    }
                }
                .frame(width: 84, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        })
    }

    /// Microphone: your voice, out to the class and into the recording.
    static var microphone: AnyView {
        AnyView(ZStack {
            stage
            HStack(spacing: 10) {
                orb("mic")
                HStack(alignment: .center, spacing: 3) {
                    ForEach([10.0, 18, 26, 16, 22, 12, 8], id: \.self) { h in
                        Capsule().fill(Brand.green).frame(width: 3, height: h)
                    }
                }
                Flow()
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { _ in Person(tint: .white.opacity(0.7)).frame(width: 16, height: 18) }
                    }
                    HStack(spacing: 5) {
                        Circle().fill(Color(nsColor: .systemRed)).frame(width: 8, height: 8)
                        Capsule().fill(.white.opacity(0.3)).frame(width: 34, height: 4)
                    }
                }
            }
        })
    }

    /// Layout: the layout itself, on a screen of your screen's shape.
    static func layout(_ pieces: [LayoutPiece]?, look: @escaping (LayoutPiece) -> LayoutPieceLook) -> AnyView {
        let screen = NSScreen.main?.frame.size ?? CGSize(width: 16, height: 10)
        let aspect = max(screen.width / max(screen.height, 1), 1.2)
        return AnyView(ZStack {
            stage
            if let pieces, !pieces.isEmpty {
                LayoutThumbnail(pieces: pieces, aspect: aspect, look: look)
                    .aspectRatio(aspect, contentMode: .fit)
                    .padding(10)
            } else {
                VStack(spacing: 5) {
                    Image(systemName: VisibilitySymbol.noPieces.name).font(.system(size: 22)).foregroundStyle(.white.opacity(0.4))
                    Text("Nothing moves").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                }
            }
        })
    }

    /// Record: the meeting, and when the recording runs along it.
    static func record(withMeeting: Bool) -> AnyView {
        AnyView(ZStack {
            stage
            VStack(alignment: .leading, spacing: 9) {
                lane("Meeting", start: 0, fill: .white.opacity(0.3))
                lane("Recording", start: withMeeting ? 0 : 0.42, fill: Color(nsColor: .systemRed).opacity(0.85), mark: !withMeeting)
            }
            .padding(.horizontal, 14)
        })
    }

    private static func lane(_ title: String, start: CGFloat, fill: Color, mark: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().fill(fill)
                        .frame(width: geo.size.width * (1 - start))
                        .offset(x: geo.size.width * start)
                    if mark {
                        Image(systemName: "hand.point.up.left.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.white)
                            .offset(x: geo.size.width * start - 5, y: 11)
                    }
                }
            }
            .frame(height: 8)
        }
    }

    /// More: the dock's button goes to Settings.
    static var more: AnyView {
        AnyView(ZStack {
            stage
            HStack(spacing: 10) { orb("ellipsis"); Flow(); orb("gearshape") }
        })
    }

    private static func orb(_ symbol: String) -> some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(.white.opacity(0.12))
            .frame(width: 38, height: 36)
            .overlay(Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(.white))
    }

    /// A dotted line, for "goes to".
    private struct Flow: View {
        var body: some View {
            HStack(spacing: 3) {
                ForEach(0..<4, id: \.self) { _ in Circle().fill(.white.opacity(0.35)).frame(width: 3, height: 3) }
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.45))
            }
        }
    }
}
