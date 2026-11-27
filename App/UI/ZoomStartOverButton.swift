//
//  ZoomStartOverButton.swift
//  Greenroom
//
//  "Start over\u{2026}" (spec R10): one quiet button and its confirmation, shared by the
//  setup guide's Zoom step and Settings -> Zoom, so there is one action and one set of words
//  (`ZoomStartOverRules`). It only asks; the caller's `action` does the forgetting.
//
import SwiftUI

struct ZoomStartOverButton: View {
    /// True while a meeting or session is live.
    let disabled: Bool
    let action: () -> Void
    @State private var confirming = false

    var body: some View {
        Button(ZoomStartOverRules.buttonTitle) { confirming = true }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.callout)
            .disabled(disabled)
            .help(ZoomStartOverRules.help(inSession: disabled))
            .confirmationDialog(ZoomStartOverRules.title, isPresented: $confirming, titleVisibility: .visible) {
                Button(ZoomStartOverRules.confirmTitle, role: .destructive, action: action)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(ZoomStartOverRules.message)
            }
    }
}
