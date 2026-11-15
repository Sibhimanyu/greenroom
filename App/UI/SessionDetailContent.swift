//
//  SessionDetailContent.swift
//  Greenroom
//
//  A session's page as a drawing: the watch page. A title and one meta line at
//  the top left, the picture at its own shape under them, one timeline under
//  the picture, and a rail on the right of three cards (Share with the class,
//  How it went, Moments). Under about 960pt the rail drops under the picture
//  and the page scrolls.
//
//  Like SessionsContent.swift this takes plain values and closures, and knows
//  nothing about the coordinator, the disk or AVKit: RecordingsView hands it
//  the picture, the timeline and the Moments content as views. DESIGN.md,
//  "A session's page".
//
import SwiftUI

// MARK: - Toolbar

/// After Back there is only Edit and a menu. Everything else moved onto the
/// page: sharing and feedback are the rail's cards, the take switch is in the
/// header, the work panel is not a thing to toggle any more.
struct SessionDetailToolbar: ToolbarContent {
    let model: SessionInspectorModel
    let actions: SessionInspectorActions

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: actions.edit) {
                Label("Edit", systemImage: "scissors")
            }
            .labelStyle(.titleAndIcon)
            .disabled(!model.canEdit)
            .help(model.canEdit
                  ? "Opens this recording in the editor. Saving makes a new recording and leaves this one untouched."
                  : "No recording to edit.")
            moreMenu
        }
    }

    private var isAnalysed: Bool {
        if case .analysed = model.analyse { return true }
        return false
    }

    private var moreMenu: some View {
        Menu {
            Button("Rename\u{2026}", action: actions.rename)
                .disabled(!model.canRename)
            Button("Show in Finder", action: actions.showInFinder)
            if isAnalysed {
                Button("Analyse again", action: actions.analyse)
            }
            Button("Analysis settings\u{2026}", action: actions.openAnalysisSetup)
            Divider()
            Button("Move to Trash\u{2026}", role: .destructive, action: actions.trash)
                .disabled(!model.canTrash)
        } label: {
            Label("More", systemImage: "ellipsis.circle")
                .foregroundStyle(Color.primary)
        }
        .menuIndicator(.hidden)
        .help("Rename, show in Finder, analysis, or move to the Trash")
    }
}

// MARK: - Page

struct SessionDetailPage<Stage: View, Timeline: View, Work: View>: View {
    let model: SessionInspectorModel
    var actions = SessionInspectorActions()
    /// False while the report is up over this page: its toolbar and the space
    /// bar then step aside.
    var isActive = true
    @Binding var take: URL?
    /// The movie's width over its height; 16:9 until the player knows.
    var aspect: CGFloat = 16.0 / 9.0
    var hasVideo = true
    var onTogglePlay: () -> Void = {}
    let tabs: [String]
    @Binding var tab: String
    @ViewBuilder let stage: () -> Stage
    @ViewBuilder let timeline: () -> Timeline
    @ViewBuilder let work: () -> Work

    private let gutter: CGFloat = 24
    private let headerHeight: CGFloat = 52
    private let timelineHeight: CGFloat = 40
    private let gap: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            if SessionDetailRules.isNarrow(width: geo.size.width) {
                narrow(geo.size)
            } else {
                wide(geo.size)
            }
        }
        .toolbar {
            if isActive { SessionDetailToolbar(model: model, actions: actions) }
        }
        .background(SpaceBarPlayback(active: isActive && hasVideo, onToggle: onTogglePlay))
        .onDeleteCommand(perform: actions.trash)
    }

    // MARK: Layouts

    private func wide(_ size: CGSize) -> some View {
        let column = size.width - SessionDetailRules.railWidth - gutter * 3
        let height = size.height - 20 - gutter
        return HStack(alignment: .top, spacing: gutter) {
            watchColumn(available: CGSize(width: column, height: height))
                .frame(width: max(0, column), height: max(0, height), alignment: .topLeading)
            rail(fillsHeight: true)
                .frame(width: SessionDetailRules.railWidth, height: max(0, height))
        }
        .padding(.horizontal, gutter)
        .padding(.top, 20)
        .padding(.bottom, gutter)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func narrow(_ size: CGSize) -> some View {
        let width = size.width - gutter * 2
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                watchColumn(available: CGSize(width: width, height: max(220, size.height * 0.55)
                                              + headerHeight + timelineHeight + gap * 2))
                rail(fillsHeight: false)
            }
            .padding(.horizontal, gutter)
            .padding(.top, 20)
            .padding(.bottom, gutter)
            .frame(width: size.width, alignment: .topLeading)
        }
    }

    /// Header, picture, timeline. The picture is sized here from the shape of
    /// the movie, so its frame is the picture and nothing else.
    private func watchColumn(available: CGSize) -> some View {
        let room = CGSize(width: available.width,
                          height: available.height - headerHeight - timelineHeight - gap * 2)
        let fitted = SessionDetailRules.fit(aspect: hasVideo ? aspect : 16.0 / 9.0, in: room)
        return VStack(alignment: .leading, spacing: gap) {
            header
                .frame(height: headerHeight, alignment: .topLeading)
            picture(fitted)
            timeline()
                .frame(width: max(fitted.width, min(available.width, 400)), height: timelineHeight,
                       alignment: .topLeading)
        }
    }

    private func picture(_ size: CGSize) -> some View {
        stage()
            .frame(width: size.width, height: size.height)
            .background(hasVideo ? Color.black : Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                if hasVideo {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onTogglePlay)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Recording")
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.title)
                .font(.system(size: 22, weight: .heavy))
                .tracking(-0.44)
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 12) {
                Text(model.headerMeta)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if model.takes.count > 1 { takeSwitch }
            }
        }
    }

    private var takeSwitch: some View {
        GreenroomSegmented("Take",
                           selection: Binding(
                            get: { take ?? model.takes.first?.id ?? URL(fileURLWithPath: "/") },
                            set: { take = $0 }),
                           options: model.takes.map(\.id)) { id in
            Text(model.takes.first { $0.id == id }.map { $0.short.isEmpty ? $0.label : $0.short } ?? "")
        }
        .controlSize(.small)
        .help("This session holds more than one recording or clip. Pick which one plays.")
    }

    // MARK: Rail

    private func rail(fillsHeight: Bool) -> some View {
        VStack(spacing: 16) {
            RailCard(caption: "Share with the class") { SessionShareCard(model: model, actions: actions) }
            RailCard(caption: "How it went") { SessionFeedbackCard(model: model, actions: actions) }
            momentsCard
                .frame(maxHeight: fillsHeight ? .infinity : nil)
                .frame(height: fillsHeight ? nil : 380)
        }
    }

    private var momentsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if tabs.count > 1 {
                GreenroomSegmented("Work", selection: $tab, options: tabs) { Text($0) }
                    .controlSize(.small)
            }
            work()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RailCardStyle.shape.fill(RailCardStyle.fill))
    }
}

// MARK: - Cards

/// One of the rail's cards: radius 14, a subtle raised fill, 16 of padding and
/// a small uppercase caption.
enum RailCardStyle {
    static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }
    static var fill: Color { Color.primary.opacity(0.05) }
}

struct RailCard<Content: View>: View {
    let caption: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(caption.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RailCardStyle.shape.fill(RailCardStyle.fill))
    }
}

/// Share with the class: the one thing that leaves this Mac, said as such.
struct SessionShareCard: View {
    let model: SessionInspectorModel
    let actions: SessionInspectorActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.youtube {
            case .noVideo:
                secondary("Nothing to share: this session has no recording.")
            case .notConnected:
                secondary("Connect a YouTube channel to share this class.")
                Button("Connect YouTube\u{2026}", action: actions.connectYouTube)
                    .controlSize(.regular)
            case .ready(let privacy):
                Button(action: actions.upload) {
                    Text("Upload as \(privacy.capitalized)").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Text("Leaves this Mac")
                    .font(.system(size: 11))
                    .foregroundStyle(Brand.netText)
            case .uploading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Uploading\u{2026}").font(.callout)
                }
                Text("Leaves this Mac")
                    .font(.system(size: 11))
                    .foregroundStyle(Brand.netText)
            case .uploaded(let privacy, _):
                uploaded(privacy: privacy)
            }
            // POST-TO-CLASS: another chat is adding a third button here, "Post to Thriveni"
            // (posts the link to the class). Put it after the upload states above, inside
            // this VStack, so the card keeps one primary action and one caption.
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func secondary(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func uploaded(privacy: String) -> some View {
        Text("On YouTube \u{00B7} \(privacy.capitalized)")
            .font(.callout.weight(.medium))
            .foregroundStyle(Brand.netText)
        if let upload = model.upload {
            Text(upload.url)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("\u{201C}\(upload.title)\u{201D}, uploaded \(upload.uploadedAt.formatted(date: .abbreviated, time: .shortened))")
        }
        HStack(spacing: 8) {
            Button("Copy", action: actions.copyLink)
            Button("Open", action: actions.openOnYouTube)
            Spacer(minLength: 0)
            Menu {
                Button("Rename on YouTube\u{2026}", action: actions.renameOnYouTube)
                Button("Delete from YouTube\u{2026}", role: .destructive, action: actions.deleteFromYouTube)
                    .disabled(!model.youtubeConnected)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Rename or delete the video on YouTube")
        }
        .controlSize(.small)
    }
}

/// How it went: the analysis, from asking for it to opening its report.
struct SessionFeedbackCard: View {
    let model: SessionInspectorModel
    let actions: SessionInspectorActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.analyse {
            case .unavailable(let why):
                secondary(why)
            case .ready(let engine, let leavesMac):
                Button(action: actions.analyse) {
                    Text("Get feedback").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                Text(engine)
                    .font(.system(size: 11))
                    .foregroundStyle(leavesMac ? AnyShapeStyle(Brand.netText) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            case .running(let step, let detail, let log):
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step).font(.callout).lineLimit(2)
                        if !detail.isEmpty {
                            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Button("Stop", role: .destructive, action: actions.stopAnalysis)
                        .controlSize(.small)
                        .help("Stops the run and closes whatever it started. Nothing is written until it finishes.")
                }
                if let last = log?.split(whereSeparator: \.isNewline).last, !last.isEmpty {
                    Text(String(last))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            case .busy:
                secondary("Another session is being analysed.")
            case .analysed(let engine, _, _):
                if let summary = model.summary {
                    Text("\u{201C}\(summary)\u{201D}")
                        .font(.callout)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    secondary("Analysed \u{00B7} \(engine)")
                }
                if let caveat = model.summaryCaveat {
                    Text(caveat).font(.caption).foregroundStyle(.secondary)
                }
                Button(action: actions.openReport) {
                    Text("Open report \u{2192}").foregroundStyle(Brand.text)
                }
                .buttonStyle(.plain)
                .font(.callout.weight(.medium))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func secondary(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Space bar

/// Space plays and pauses the picture, but only when nothing is being typed.
/// A local key monitor, not a keyboard shortcut on a button: a shortcut would
/// take the space out of the note box and every other text field. It checks
/// the window's first responder every press (SessionDetailRules decides).
private struct SpaceBarPlayback: NSViewRepresentable {
    let active: Bool
    let onToggle: () -> Void

    final class Coordinator {
        var active = false
        var onToggle: () -> Void = {}
        weak var window: NSWindow?
        var monitor: Any?

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.keyCode == 49, let window = self.window,
                      event.window === window else { return event }
                let responder = window.firstResponder
                let allow = SessionDetailRules.spaceTogglesPlayback(
                    textInputFocused: responder is NSText || responder is NSTextView,
                    controlFocused: responder is NSControl,
                    hasModifiers: !event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                    sheetUp: window.attachedSheet != nil,
                    pageActive: self.active && window.isKeyWindow)
                guard allow else { return event }
                self.onToggle()
                return nil
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { remove() }
    }

    final class Anchor: NSView {
        var onWindow: (NSWindow?) -> Void = { _ in }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow(window)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> Anchor {
        let anchor = Anchor()
        let coordinator = context.coordinator
        anchor.onWindow = { window in
            coordinator.window = window
            if window == nil { coordinator.remove() } else { coordinator.install() }
        }
        return anchor
    }

    func updateNSView(_ view: Anchor, context: Context) {
        context.coordinator.active = active
        context.coordinator.onToggle = onToggle
    }

    static func dismantleNSView(_ view: Anchor, coordinator: Coordinator) {
        coordinator.remove()
    }
}

// MARK: - Empty states

/// A tab with nothing in it: glyph, one line, and the action that fills it.
struct SessionTabEmpty<Actions: View>: View {
    let title: String
    let symbol: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        // Compact, in the upper third: a quiet note, not the page.
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            actions()
        }
        .frame(maxWidth: 260)
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
