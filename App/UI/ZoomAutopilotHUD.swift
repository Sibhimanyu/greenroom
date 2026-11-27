//
//  ZoomAutopilotHUD.swift
//  Greenroom
//
//  While Set up for me drives Zoom's page, this covers the page: a soft dim that takes every
//  click (so nothing knocks the run off course) and a glass card with the step, a progress bar
//  and Stop (owner, 2026-11-27). When the run needs the person (sign-in), the card says so and
//  the cover lifts so they can type; it comes back when the run carries on.
//  Plain values and a closure, so it renders off screen.
//
import SwiftUI

struct ZoomAutopilotHUD: View {
    /// "Step 6 of 8 · Add the permissions…"
    let line: String
    /// 1...total, or nil before the first step.
    let step: Int?
    let total: Int
    /// What the person must do now (sign in), or nil while Greenroom drives.
    let needsYou: String?
    /// The card's title while the person acts (sign-in by default).
    var needsYouTitle: String? = nil
    let onStop: () -> Void

    var body: some View {
        // While the person signs in the card sits at the top, clear of Zoom's sign-in form.
        ZStack(alignment: needsYou == nil ? .bottom : .top) {
            if needsYou == nil {
                // The cover: takes clicks and scrolls, shows the page through it.
                Rectangle()
                    .fill(Color.black.opacity(0.28))
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .accessibilityHidden(true)
            }
            card
                .padding(needsYou == nil ? .bottom : .top, needsYou == nil ? 28 : 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: needsYou == nil ? .bottom : .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
                Text(needsYou == nil ? "Greenroom is setting up Zoom" : (needsYouTitle ?? "Sign in to Zoom to continue"))
                    .font(.headline)
                Spacer(minLength: 12)
                if needsYou == nil {
                    // Quiet: Stop is there if wanted, never the thing to do (owner, 2026-11-27). The bar has it too.
                    Button("Stop", action: onStop)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Stop Set up for me. The guided steps carry on from where it is.")
                }
            }
            Text(needsYou ?? line)
                .font(.callout)
                .foregroundStyle(needsYou == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .fixedSize(horizontal: false, vertical: true)
            if needsYou == nil {
                ProgressView(value: Double(max(0, (step ?? 1) - 1)), total: Double(max(1, total)))
                    .tint(Brand.green)
                Text("Please don’t click on the page until it’s done.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(width: 420)
        .greenroomGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(needsYou == nil ? "Greenroom is setting up Zoom. \(line)" : (needsYou ?? ""))
    }
}
