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

/// The GeometryReader ignores the safe area so it reports the toolbar's height
/// and spans the page frame; the mask rectangle starts below it.
private struct PageScrollClip: ViewModifier {
    func body(content: Content) -> some View {
        content
            .pageScrollEdge()
            .mask {
                GeometryReader { proxy in
                    Rectangle().padding(.top, proxy.safeAreaInsets.top)
                }
                .ignoresSafeArea()
            }
    }
}

#Preview("Page chrome") {
    Text("A page")
        .frame(width: 420, height: 200)
        .pageToolbar(back: PageBack(label: "Sessions", action: {}), subtitle: "Monday meeting")
}
