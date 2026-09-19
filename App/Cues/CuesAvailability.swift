//
//  CuesAvailability.swift
//  Greenroom
//
//  The one switch that holds Cues in or out of a release.
//
//  Cues works. It has shipped through real classes, it has a bench, and the
//  code is all here. It was held back because a release goes out before a
//  feature is ready to be supported in front of people who did not build it;
//  it is on now so it can be tested in a real class again.
//
//  This exists as a single constant rather than as "leave the toggle off"
//  because the toggle is not the only door. `prompterEnabled` is already
//  written into UserDefaults on every Mac that has run an earlier build, and
//  an imported settings file carries it too, so a release that only hid the
//  switch would still start listening for anyone upgrading. Every door checks
//  this constant instead:
//
//    - Settings -> Cues            (the tab shows a coming-soon row)
//    - Onboarding step 6           (same row, compact)
//    - startCuesIfEnabled()        (refuses to start, whatever the default says)
//    - importSettings()            (an imported file cannot switch it on)
//
//  To ship Cues: set `isReleased` to true. Nothing else needs changing, and
//  every stored preference is still where its owner left it.
//
import SwiftUI

enum CuesAvailability {

    /// True since 2026-09-19, on the author's call: "unlock it so we can
    /// start testing."
    ///
    /// The four doors below are kept rather than deleted. The switch is how
    /// Cues goes back behind the curtain if a class goes badly, and the
    /// reasoning in the file note - that a stored `prompterEnabled` and an
    /// imported settings file are doors the toggle does not close - is still
    /// why they all read this constant instead of the preference.
    ///
    /// The four gates read this directly rather than through a combined
    /// "can it run here" helper, so a macOS 14 Mac sees the coming-soon row
    /// too, instead of the older "Cues needs macOS 26" sentence for a
    /// feature that is not in the build on any OS.
    static let isReleased = true
}

/// What Settings and Onboarding show in place of the real controls.
///
/// Deliberately keeps the live toggle's own title and subtitle: this is the
/// same feature, described the same way, so someone who reads about Cues and
/// then opens Settings finds the thing they read about rather than a stub.
/// `compact` drops the section header for the onboarding wizard, matching
/// `CuesSetupRows`.
struct CuesComingSoonRows: View {
    var compact: Bool = false

    var body: some View {
        Section {
            LabeledContent {
                Text("Coming soon")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.quaternary))
                    .accessibilityLabel("Coming soon. This feature is not available in this version.")
            } label: {
                SettingLabel(title: "Listen during classes and suggest links",
                             subtitle: "Cards for the tools, words, quotes, books, videos, topics and people you name.")
            }
            .disabled(true)
        } header: {
            if !compact { Text("Cues") }
        } footer: {
            Text("Cues is still being finished and is not part of this release. Nothing listens to your microphone, and the rest of Greenroom works exactly as it does today.")
        }
    }
}
