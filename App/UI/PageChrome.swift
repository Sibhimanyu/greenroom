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

#Preview("Page chrome") {
    Text("A page")
        .frame(width: 420, height: 200)
        .pageToolbar(back: PageBack(label: "Sessions", action: {}), subtitle: "Monday class")
}
