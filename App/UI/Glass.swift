//
//  Glass.swift
//
//  The one look for everything that floats over content: HUDs, banners,
//  toasts, pills, floating toolbars. Liquid Glass on macOS 26, a material
//  with a hairline before that. Never hand-pick a material (DESIGN.md, Glass).
//
import SwiftUI
import AppKit

extension View {
    /// Floating control surface. `interactive` lets the glass react to
    /// touch/pointer (use it for tappable pills, not for read-only cards).
    @ViewBuilder
    func greenroomGlass<S: InsettableShape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            let glass: Glass = interactive ? .regular.interactive() : .regular
            self.glassEffect(glass, in: shape)
        } else {
            self
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1))
        }
    }
}

extension View {
    /// A button on an in-content control bar (transport):
    /// glass on macOS 26, the bordered styles before. Not for toolbar items,
    /// which the system styles itself.
    @ViewBuilder
    func greenroomGlassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }
}

/// Groups neighbouring glass pieces so they blend and sample together on
/// macOS 26; a plain pass-through before that.
struct GreenroomGlassGroup<Content: View>: View {
    var spacing: CGFloat? = nil
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

enum GreenroomGlassAppKit {
    /// Backing view for a borderless floating panel. The panel must be
    /// non-opaque with a clear background, or the glass has nothing to refract.
    /// `content` is placed inside (macOS 26) or added as a subview (before).
    static func makeBacking(cornerRadius: CGFloat, content: NSView? = nil) -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            if let content {
                content.translatesAutoresizingMaskIntoConstraints = false
                glass.contentView = content
            }
            return glass
        }
        let backing = NSVisualEffectView()
        backing.material = .hudWindow
        backing.blendingMode = .behindWindow
        backing.state = .active
        backing.wantsLayer = true
        backing.layer?.cornerRadius = cornerRadius
        backing.layer?.masksToBounds = true
        if let content {
            content.translatesAutoresizingMaskIntoConstraints = false
            backing.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: backing.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: backing.trailingAnchor),
                content.topAnchor.constraint(equalTo: backing.topAnchor),
                content.bottomAnchor.constraint(equalTo: backing.bottomAnchor),
            ])
        }
        return backing
    }

    /// Where to add arbitrary subviews: the glass view's contentView on 26,
    /// the backing itself otherwise.
    static func host(of backing: NSView) -> NSView {
        if #available(macOS 26, *), let glass = backing as? NSGlassEffectView {
            if glass.contentView == nil {
                let inner = NSView()
                glass.contentView = inner
            }
            return glass.contentView!
        }
        return backing
    }

    /// Make a panel suitable for glass.
    static func prepare(_ window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
    }
}
