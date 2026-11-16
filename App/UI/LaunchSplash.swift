//
//  LaunchSplash.swift
//  Greenroom
//
//  The launch (owner, 2026-11-16: "a nice animation with the Greenroom logo",
//  the same frosted blur as RasanAI's opening). The window opens frosted and
//  the mark tells its own story: the G pulls into focus out of a blur, the
//  lime head drops into its mouth (the teacher stepping in), the name rises
//  out of the blur under it; then the frost dissolves and Home comes into
//  focus. Once per launch, about 2 s. Reduce Motion fades the mark in and
//  out, nothing moves or blurs.
//
//  All motion is Core Animation, so a main thread busy launching cannot drop
//  its frames, and it begins when the window is really on screen.
//
import AppKit
import SwiftUI

/// Frosts the whole window, title bar and toolbar included, while the mark
/// plays. Attach once, to the main window's root view.
struct LaunchSplashCover: NSViewRepresentable {
    /// Once per process: a main window re-created later opens plainly.
    @MainActor static var played = false

    final class Anchor: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window); onWindow = nil }
        }
    }

    func makeNSView(context: Context) -> Anchor {
        let anchor = Anchor()
        guard !Self.played else { return anchor }
        Self.played = true
        let cover = context.coordinator
        anchor.onWindow = { window in MainActor.assumeIsolated { cover.install(over: window) } }
        return anchor
    }

    func updateNSView(_ anchor: Anchor, context: Context) {}

    func makeCoordinator() -> Cover { Cover() }

    #if DEBUG
    @MainActor private static var replaying: Cover?
    /// The debug tour's `splash`: the launch again, for screenshots.
    @MainActor static func replay(over window: NSWindow) {
        let cover = Cover()
        replaying = cover
        cover.install(over: window)
    }
    #endif

    @MainActor final class Cover: NSObject, CAAnimationDelegate {
        private var frost: NSVisualEffectView?
        private var content: SplashMarkView?
        private var occlusion: NSObjectProtocol?
        private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        func install(over window: NSWindow) {
            guard frost == nil, let frame = window.contentView?.superview else { return }
            let frost = NSVisualEffectView(frame: frame.bounds)
            frost.material = .underWindowBackground
            frost.blendingMode = .withinWindow
            frost.state = .active
            frost.wantsLayer = true
            frost.autoresizingMask = [.width, .height]
            let content = SplashMarkView(reduceMotion: reduceMotion)
            content.frame = frost.bounds
            content.autoresizingMask = [.width, .height]
            frost.addSubview(content)
            frame.addSubview(frost, positioned: .above, relativeTo: nil)
            self.frost = frost
            self.content = content
            DockHintPanel.shared.splashUp = true
            if window.isVisible, window.occlusionState.contains(.visible) {
                begin()
            } else {
                occlusion = NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard window.occlusionState.contains(.visible) else { return }
                        self?.begin()
                    }
                }
            }
            // Never longer than this, even if the window never shows.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.dissolve() }
        }

        private func begin() {
            if let occlusion { NotificationCenter.default.removeObserver(occlusion); self.occlusion = nil }
            guard let content, !content.started else { return }
            content.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.9 : 1.75)) { [weak self] in
                self?.dissolve()
            }
        }

        /// The mark leaves first and quicker; the frost follows, and Home
        /// comes into focus underneath it.
        private func dissolve() {
            guard let frost, let layer = frost.layer, !(content?.leaving ?? true) || content == nil else { return }
            content?.leave()
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1; fade.toValue = 0
            fade.duration = reduceMotion ? 0.25 : 0.55
            fade.beginTime = reduceMotion ? 0 : 0.12
            fade.fillMode = .backwards
            fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0, 0.2, 1)
            let group = CAAnimationGroup()
            group.animations = [fade]
            group.duration = fade.beginTime + fade.duration
            group.delegate = self
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.opacity = 0
            CATransaction.commit()
            layer.add(group, forKey: "dissolve")
        }

        nonisolated func animationDidStop(_ animation: CAAnimation, finished: Bool) {
            MainActor.assumeIsolated {
                frost?.removeFromSuperview()
                DockHintPanel.shared.splashUp = false
                frost = nil
                content = nil
            }
        }
    }
}

/// The mark and the name, centred, built from layers so each piece can blur,
/// move and fade on its own clock.
@MainActor final class SplashMarkView: NSView {
    /// The mark's own grid (Branding/greenroom-mark.svg): 988 × 1024.
    private static let grid = CGSize(width: 988, height: 1024)
    private static let markHeight: CGFloat = 76
    private static let gap: CGFloat = 18
    /// Room around each piece for its blur to spread into.
    private static let bleed: CGFloat = 40

    private let bodyHolder = CALayer()
    private let headHolder = CALayer()
    private let nameHolder = CALayer()
    private let reduceMotion: Bool
    private(set) var started = false
    private(set) var leaving = false

    init(reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        super.init(frame: .zero)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        setAccessibilityElement(true)
        setAccessibilityLabel("Greenroom")

        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        var ink = NSColor.white.cgColor
        if !dark { NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { ink = NSColor(Brand.name).cgColor } }
        let lime = NSColor(srgbRed: 0x78 / 255.0, green: 0xC0 / 255.0, blue: 0, alpha: 1).cgColor

        let scale = Self.markHeight / Self.grid.height
        var flip = CGAffineTransform(translationX: 0, y: Self.markHeight).scaledBy(x: scale, y: -scale)
        for (holder, path, colour) in [(bodyHolder, Self.body, ink), (headHolder, Self.head, lime)] {
            let shape = CAShapeLayer()
            shape.path = path.copy(using: &flip)
            shape.fillColor = colour
            shape.frame = CGRect(x: Self.bleed, y: Self.bleed,
                                 width: Self.grid.width * scale, height: Self.markHeight)
            holder.addSublayer(shape)
            prepare(holder)
        }

        let name = CATextLayer()
        name.string = NSAttributedString(string: "Greenroom", attributes: [
            .font: NSFont.systemFont(ofSize: 28, weight: .bold),
            .foregroundColor: NSColor(cgColor: ink) ?? .labelColor,
            .kern: -0.3,
        ])
        name.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        name.alignmentMode = .center
        let nameSize = (name.string as? NSAttributedString)?.size() ?? .zero
        name.frame = CGRect(x: Self.bleed, y: Self.bleed, width: ceil(nameSize.width) + 2, height: ceil(nameSize.height))
        nameHolder.addSublayer(name)
        prepare(nameHolder)
        for holder in [bodyHolder, headHolder, nameHolder] { layer?.addSublayer(holder) }
    }

    required init?(coder: NSCoder) { nil }

    private func prepare(_ holder: CALayer) {
        let size = holder.sublayers?.first?.frame.size ?? .zero
        holder.bounds = CGRect(x: 0, y: 0, width: size.width + Self.bleed * 2, height: size.height + Self.bleed * 2)
        holder.opacity = 0
        if !reduceMotion, let blur = CIFilter(name: "CIGaussianBlur") {
            blur.name = "blur"
            blur.setValue(0, forKey: kCIInputRadiusKey)
            holder.filters = [blur]
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let nameHeight = (nameHolder.bounds.height - Self.bleed * 2)
        let total = Self.markHeight + Self.gap + nameHeight
        // Layer y grows upward here (not flipped): the mark above the name,
        // the pair a touch above the middle, where the eye expects it.
        let top = bounds.midY + total / 2 + 8
        let markCentre = CGPoint(x: bounds.midX, y: top - Self.markHeight / 2)
        bodyHolder.position = markCentre
        headHolder.position = markCentre
        nameHolder.position = CGPoint(x: bounds.midX, y: top - Self.markHeight - Self.gap - nameHeight / 2)
        CATransaction.commit()
    }

    // MARK: Motion

    func start() {
        guard !started else { return }
        started = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for holder in [bodyHolder, headHolder, nameHolder] { holder.opacity = 1 }
        CATransaction.commit()
        if reduceMotion {
            for holder in [bodyHolder, headHolder, nameHolder] {
                holder.add(basic("opacity", from: 0, to: 1, duration: 0.3), forKey: "in")
            }
            return
        }
        let out = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)

        // The G: out of focus and a touch large, pulling sharp.
        bodyHolder.add(group([
            basic("opacity", from: 0, to: 1, duration: 0.3),
            basic("filters.blur.inputRadius", from: 22, to: 0, duration: 0.75, timing: out),
            spring("transform.scale", from: 1.14, to: 1, response: 0.7, damping: 0.9),
        ], at: 0), forKey: "in")

        // The head: dropped in from above and a little turned, landing in the
        // G's mouth with a small give.
        let drop = Self.markHeight * 0.55
        headHolder.add(group([
            basic("opacity", from: 0, to: 1, duration: 0.15),
            basic("filters.blur.inputRadius", from: 10, to: 0, duration: 0.35, timing: out),
            spring("transform.translation.y", from: Double(drop), to: 0, response: 0.42, damping: 0.62),
            spring("transform.rotation.z", from: -0.35, to: 0, response: 0.5, damping: 0.7),
        ], at: 0.42), forKey: "in")

        // The name: rising out of the blur under the mark.
        nameHolder.add(group([
            basic("opacity", from: 0, to: 1, duration: 0.4, timing: out),
            basic("filters.blur.inputRadius", from: 12, to: 0, duration: 0.6, timing: out),
            spring("transform.translation.y", from: -12, to: 0, response: 0.6, damping: 0.88),
        ], at: 0.72), forKey: "in")
    }

    /// Out: everything blurs back and fades, a little smaller, quicker than it came.
    func leave() {
        guard !leaving else { return }
        leaving = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for holder in [bodyHolder, headHolder, nameHolder] { holder.opacity = 0 }
        CATransaction.commit()
        for holder in [bodyHolder, headHolder, nameHolder] {
            var parts: [CAAnimation] = [basic("opacity", from: 1, to: 0, duration: reduceMotion ? 0.2 : 0.32)]
            if !reduceMotion {
                parts.append(basic("filters.blur.inputRadius", from: 0, to: 14, duration: 0.32))
                parts.append(basic("transform.scale", from: 1, to: 0.96, duration: 0.32))
            }
            holder.add(group(parts, at: 0), forKey: "out")
        }
    }

    private func basic(_ key: String, from: Double, to: Double, duration: Double,
                       timing: CAMediaTimingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0, 0.2, 1)) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = from; a.toValue = to; a.duration = duration; a.timingFunction = timing
        a.fillMode = .both; a.isRemovedOnCompletion = false
        return a
    }

    /// SwiftUI's `.spring(response:dampingFraction:)` as Core Animation: unit
    /// mass, stiffness (2π / response)², damping 2ζ√stiffness.
    private func spring(_ key: String, from: Double, to: Double, response: Double, damping: Double) -> CASpringAnimation {
        let omega = 2 * Double.pi / response
        let s = CASpringAnimation(keyPath: key)
        s.mass = 1; s.stiffness = omega * omega; s.damping = 2 * damping * omega
        s.fromValue = from; s.toValue = to
        s.duration = s.settlingDuration
        s.fillMode = .both
        return s
    }

    /// Animations start at `delay` after the group commits; before then they
    /// hold their first value.
    private func group(_ parts: [CAAnimation], at delay: Double) -> CAAnimationGroup {
        var end = 0.0
        for part in parts {
            part.beginTime = delay
            part.fillMode = .both
            end = max(end, delay + part.duration)
        }
        let g = CAAnimationGroup()
        g.animations = parts
        g.duration = end
        g.fillMode = .both
        g.isRemovedOnCompletion = false
        return g
    }

    // MARK: The mark's shapes (Branding/greenroom-mark.svg, top-down)

    private static func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    static let body: CGPath = {
        let p = CGMutablePath()
        p.move(to: P(0.00, 245.76))
        p.addCurve(to: P(245.76, 0.00), control1: P(0.00, 110.03), control2: P(110.03, 0.00))
        p.addLine(to: P(599.04, 0.00))
        p.addCurve(to: P(670.72, 71.68), control1: P(638.63, 0.00), control2: P(670.72, 32.09))
        p.addLine(to: P(670.72, 168.96))
        p.addCurve(to: P(599.04, 240.64), control1: P(670.72, 208.55), control2: P(638.63, 240.64))
        p.addLine(to: P(281.60, 240.64))
        p.addCurve(to: P(240.64, 281.60), control1: P(258.98, 240.64), control2: P(240.64, 258.98))
        p.addLine(to: P(240.64, 742.40))
        p.addCurve(to: P(281.60, 783.36), control1: P(240.64, 765.02), control2: P(258.98, 783.36))
        p.addLine(to: P(706.56, 783.36))
        p.addCurve(to: P(747.52, 742.40), control1: P(729.18, 783.36), control2: P(747.52, 765.02))
        p.addLine(to: P(747.52, 612.78))
        p.addCurve(to: P(722.57, 592.79), control1: P(747.52, 599.67), control2: P(735.37, 589.93))
        p.addLine(to: P(565.52, 627.89))
        p.addCurve(to: P(479.93, 573.57), control1: P(526.88, 636.53), control2: P(488.57, 612.21))
        p.addLine(to: P(479.93, 573.57))
        p.addCurve(to: P(534.25, 487.98), control1: P(471.29, 534.94), control2: P(495.61, 496.62))
        p.addLine(to: P(744.21, 441.05))
        p.addCurve(to: P(750.91, 440.31), control1: P(746.41, 440.56), control2: P(748.66, 440.31))
        p.addLine(to: P(931.84, 440.31))
        p.addCurve(to: P(988.16, 496.63), control1: P(962.94, 440.31), control2: P(988.16, 465.52))
        p.addLine(to: P(988.16, 880.63))
        p.addCurve(to: P(844.80, 1023.99), control1: P(988.16, 959.81), control2: P(923.98, 1023.99))
        p.addLine(to: P(245.76, 1023.99))
        p.addCurve(to: P(0.00, 778.24), control1: P(110.03, 1024.00), control2: P(0.00, 913.97))
        p.addLine(to: P(0.00, 245.76))
        p.closeSubpath()
        return p
    }()
    static let head: CGPath = {
        let p = CGMutablePath()
        p.move(to: P(747.52, 235.52))
        p.addCurve(to: P(824.32, 158.72), control1: P(747.52, 193.10), control2: P(781.91, 158.72))
        p.addLine(to: P(911.36, 158.72))
        p.addCurve(to: P(988.16, 235.52), control1: P(953.77, 158.72), control2: P(988.16, 193.10))
        p.addLine(to: P(988.16, 322.56))
        p.addCurve(to: P(911.36, 399.36), control1: P(988.16, 364.98), control2: P(953.77, 399.36))
        p.addLine(to: P(824.32, 399.36))
        p.addCurve(to: P(747.52, 322.56), control1: P(781.90, 399.36), control2: P(747.52, 364.98))
        p.addLine(to: P(747.52, 235.52))
        p.closeSubpath()
        return p
    }()
}
