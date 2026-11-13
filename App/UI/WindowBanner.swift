//
//  WindowBanner.swift
//  Greenroom
//
//  Greenroom keeps a low profile: while the main window is open and in view,
//  the things that used to float over the screen - a toast, the upload
//  question and the start's progress card - are drawn inside it instead. The
//  floating panels stay for when the window is closed, minimised or covered,
//  which is the class itself: Zoom and Chrome tiled over everything, and a
//  hotkey toast still has to land on the screen the teacher is looking at.
//
//  ToastController, UploadPromptCard and ReadinessHUDController keep their
//  APIs and ask `MainWindowPresence` where to draw. This file is the in-window
//  half: one observable holding what is showing, and one overlay drawing it.
//
import SwiftUI
import AppKit

/// Whether the main window is somewhere a person is looking.
enum MainWindowPresence {
    static var window: NSWindow? {
        MainActor.assumeIsolated { MainWindow.current }
    }

    /// Open, not minimised, not entirely covered, and Greenroom is the app in
    /// front. Occlusion alone is not enough: a window half under tiled Zoom
    /// or Chrome still counts as visible, and a banner drawn in its hidden
    /// half is a message nobody sees. When another app is in front, the
    /// floating panel is the one that is certain to be seen.
    static var isVisible: Bool {
        guard let window else { return false }
        return NSApp.isActive && window.isVisible && !window.isMiniaturized
            && window.occlusionState.contains(.visible)
    }
}

@MainActor
final class BannerCenter: ObservableObject {
    static let shared = BannerCenter()

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
    @Published private(set) var readiness: ParticipantGridWindowController.Readiness?

    private var toastTask: Task<Void, Never>?
    private var readinessTask: Task<Void, Never>?

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

    func showReadiness(_ value: ParticipantGridWindowController.Readiness) {
        // Nothing left to report. A failure stays; otherwise a beat on the
        // ticked list before it goes, as the floating card does.
        guard !value.steps.isEmpty || value.failure != nil else {
            guard readiness != nil, readinessTask == nil else { return }
            readinessTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard !Task.isCancelled else { return }
                hideReadiness()
            }
            return
        }
        readinessTask?.cancel()
        readinessTask = nil
        if readiness == nil {
            withAnimation(.easeOut(duration: 0.25)) { readiness = value }
        } else {
            readiness = value
        }
    }

    func hideReadiness() {
        readinessTask?.cancel()
        readinessTask = nil
        guard readiness != nil else { return }
        withAnimation(.easeIn(duration: 0.25)) { readiness = nil }
    }
}

/// Over the main window's content: the progress card centred, and below it
/// the toast and the upload question, low and centred like the floating ones.
struct WindowBannerOverlay: View {
    @ObservedObject private var banners = BannerCenter.shared

    var body: some View {
        ZStack {
            if let readiness = banners.readiness {
                ReadinessBanner(readiness: readiness)
                    .transition(.opacity)
            }
            VStack(spacing: 12) {
                Spacer(minLength: 0)
                if let prompt = banners.prompt {
                    PromptBanner(item: prompt)
                        .transition(.opacity)
                }
                if let toast = banners.toast {
                    ToastBanner(item: toast)
                        .transition(.opacity)
                }
            }
            .padding(.bottom, 28)
        }
        .padding(.horizontal, 32)
        // Only the cards take clicks; the window under them keeps its own.
        .allowsHitTesting(banners.prompt != nil || banners.readiness?.failure != nil)
    }
}

/// The card surface all three share: the HUD's material and radius-lg.
private struct BannerCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(14)
            .greenroomGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
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
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: item.kind.symbol)
                    .foregroundStyle(tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    if let detail = item.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .frame(maxWidth: 340, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PromptBanner: View {
    let item: BannerCenter.PromptItem

    var body: some View {
        BannerCard {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Brand.green)
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(2)
                    Text(item.detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Spacer(minLength: 0)
                        Button("Not now") { UploadPromptCard.notNow() }
                        Button(item.uploadTitle) { UploadPromptCard.upload() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 6)
                }
            }
            .frame(maxWidth: 440, alignment: .leading)
        }
    }
}

/// The start's steps, in the window. The same card as the floating one:
/// a bar, the named steps, the newest status line, and on a failure the
/// reason with its way out.
private struct ReadinessBanner: View {
    let readiness: ParticipantGridWindowController.Readiness

    var body: some View {
        BannerCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(readiness.failure == nil ? "GETTING READY" : "COULD NOT START")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.2))
                        // A fill, which is the one thing DESIGN.md allows the lime to be.
                        Capsule().fill(Brand.fill)
                            .frame(width: proxy.size.width * fraction)
                            .animation(.easeInOut(duration: 0.25), value: fraction)
                    }
                }
                .frame(height: 3)

                ForEach(Array(readiness.steps.enumerated()), id: \.offset) { _, step in
                    row(step)
                }

                if let failure = readiness.failure {
                    Text(failure)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Spacer(minLength: 0)
                        Button("Close") {
                            Task { @MainActor in ParticipantGridWindowController.readinessDismiss?() }
                        }
                        Button("Try again") {
                            Task { @MainActor in ParticipantGridWindowController.readinessTryAgain?() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if let detail = readiness.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(width: 320 - 28, alignment: .leading)
        }
    }

    private var fraction: Double {
        readiness.steps.isEmpty ? 0 : Double(readiness.settled) / Double(readiness.steps.count)
    }

    private func row(_ step: ParticipantGridWindowController.Readiness.Step) -> some View {
        HStack(spacing: 8) {
            Group {
                switch step.state {
                case .pending:
                    Image(systemName: "circle").foregroundStyle(.secondary)
                case .active:
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.green)
                case .skipped:
                    Image(systemName: "minus.circle").foregroundStyle(.secondary)
                case .failed:
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                }
            }
            .frame(width: 16, height: 16)
            Text(step.label)
                .font(.system(size: 13))
                .foregroundStyle(style(step.state))
        }
    }

    private func style(_ state: ParticipantGridWindowController.Readiness.State) -> AnyShapeStyle {
        switch state {
        case .pending, .skipped: return AnyShapeStyle(.secondary)
        case .active: return AnyShapeStyle(.primary)
        case .done: return AnyShapeStyle(.secondary)
        case .failed: return AnyShapeStyle(Color.red)
        }
    }
}
