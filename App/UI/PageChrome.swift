//
//  PageChrome.swift
//
//  Window chrome for a page of the main window: the Back button (⌘[), and the
//  page's name as the window subtitle. DESIGN.md, "Chrome is the system's".
//
//  Uses `navigationSubtitle`, NOT `navigationTitle`. The main window is still
//  found by `title == "Greenroom"` in ContentView.window and
//  CoordinatorController, and a navigation title would rename the window and
//  silently break resize, show-window and ordering. C10 switches those callers
//  to `MainWindow.current`; only then may a page set a title.
//
import AppKit
import SwiftUI

struct PageBack {
    /// Where Back goes, named for the button's help and VoiceOver ("Sessions").
    var label: String
    var action: () -> Void
}

extension View {
    /// `back == nil` shows no Back button (Home).
    func pageToolbar(back: PageBack?, subtitle: String) -> some View {
        self
            .navigationSubtitle(subtitle)
            // The title bar shows the window's frost too, rather than a band of
            // its own opaque material over it (owner, 2026-11-16).
            .toolbarBackground(.hidden, for: .windowToolbar)
            .toolbar {
                if let back {
                    ToolbarItem(placement: .navigation) {
                        Button(action: back.action) {
                            Label(back.label, systemImage: "chevron.backward")
                        }
                        .keyboardShortcut("[", modifiers: .command)
                        .help("Back to \(back.label) (⌘[)")
                    }
                }
            }
    }
}

extension View {
    /// Scrolled content ends at the bottom edge of the toolbar instead of
    /// showing through its buttons (owner, 2026-11-20). The title bar is
    /// transparent (WindowFrost) and the toolbar background hidden, so the
    /// frost stays and nothing is painted: the page is masked to the area
    /// below the top safe area, and on macOS 26 the system's hard top scroll
    /// edge effect is set too. At rest a page's content already starts below
    /// the toolbar, so nothing moves. Every scrolling page of the main window
    /// and every Settings tab uses this.
    func pageScrollClip() -> some View {
        modifier(PageScrollClip())
    }

    /// Only the hard top scroll edge, for a ScrollView or List that cannot
    /// rely on the container's environment reaching it.
    @ViewBuilder
    func pageScrollEdge() -> some View {
        if #available(macOS 26.0, *) {
            self.scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            self
        }
    }
}

/// The mask starts below the toolbar. Two measurements, the larger wins: the
/// SwiftUI top safe area, and the window's own `contentLayoutRect` (how far
/// this page reaches above the layout area under the title bar and tab row).
/// In a Settings `TabView` the safe area can read 0 while the page still
/// scrolls under the tabs, so the AppKit measure is the one that holds.
private struct PageScrollClip: ViewModifier {
    @State private var overhang: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .pageScrollEdge()
            .background(ToolbarOverhangProbe(overhang: $overhang))
            .mask {
                GeometryReader { proxy in
                    Rectangle().padding(.top, max(proxy.safeAreaInsets.top, overhang))
                }
                .ignoresSafeArea()
            }
    }
}

/// Reports how many points of this view sit above the window's content layout
/// rect (the toolbar and title bar band). Paints nothing, takes no clicks.
private struct ToolbarOverhangProbe: NSViewRepresentable {
    @Binding var overhang: CGFloat

    final class Probe: NSView {
        var onChange: (CGFloat) -> Void = { _ in }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() { super.layout(); measure() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); measure() }
        override func viewDidEndLiveResize() { super.viewDidEndLiveResize(); measure() }

        func measure() {
            guard let window else { return }
            let inWindow = convert(bounds, to: nil)
            let top = window.contentLayoutRect.maxY
            let value = max(0, ceil(inWindow.maxY - top))
            DispatchQueue.main.async { [onChange] in onChange(value) }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.onChange = { value in if overhang != value { overhang = value } }
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.onChange = { value in if overhang != value { overhang = value } }
        probe.measure()
    }
}

#Preview("Page chrome") {
    Text("A page")
        .frame(width: 420, height: 200)
        .pageToolbar(back: PageBack(label: "Sessions", action: {}), subtitle: "Monday meeting")
}
