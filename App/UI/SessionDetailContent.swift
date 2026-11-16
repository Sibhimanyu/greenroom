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

/// The Watch / Edit switch in the middle; on the right, Undo, Redo and Save
/// while editing, or the More menu while watching. Everything else is on the
/// page: sharing and feedback are the rail's cards, the take switch is in the
/// header.
struct SessionDetailToolbar: ToolbarContent {
    let model: SessionInspectorModel
    let actions: SessionInspectorActions
    var isEditing = false
    var onMode: (Bool) -> Void = { _ in }
    var canUndo = false
    var canRedo = false
    var canSave = false
    var onUndo: () -> Void = {}
    var onRedo: () -> Void = {}
    var onSave: () -> Void = {}
    var onShare: () -> Void = {}

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            GreenroomSegmented("Mode",
                               selection: Binding(get: { isEditing ? "Edit" : "Watch" },
                                                  set: { onMode($0 == "Edit") }),
                               options: ["Watch", "Edit"],
                               toolbar: true) { Text($0) }
                .help(model.canEdit
                      ? "Watch plays the recording. Edit adds the tools. Saving makes a new recording and leaves this one untouched."
                      : "No recording to edit.")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if isEditing {
                Button(action: onUndo) { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(!canUndo)
                    .help("Undo the last edit (\u{2318}Z)")
                Button(action: onRedo) { Label("Redo", systemImage: "arrow.uturn.forward") }
                    .disabled(!canRedo)
                    .help("Redo (\u{21E7}\u{2318}Z)")
                // Quiet until there is something to save.
                if canSave {
                    Button(action: onSave) { Text("Save") }
                        .buttonStyle(.borderedProminent)
                        .help("Save the edits as a new recording")
                } else {
                    Button(action: onSave) { Text("Save") }
                        .disabled(true)
                        .help("Nothing to save yet")
                }
            } else {
                Button(action: onShare) {
                    Label("Share\u{2026}", systemImage: "square.and.arrow.up")
                }
                .labelStyle(.titleAndIcon)
                .help("Share this class: YouTube, or post the link to the class")
                moreMenu
            }
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

/// One page, two modes. The header, the picture and the timeline sit in the
/// same place in both. Watch puts the rail's cards on the right; Edit adds the
/// tools between picture and timeline, and "Your edits" in place of the rail.
struct SessionDetailPage<Stage: View, Timeline: View, Work: View, Transcript: View>: View {
    @EnvironmentObject private var editor: EditorViewModel
    @StateObject private var chrome = EditorChrome()
    @State private var showShare = false

    let model: SessionInspectorModel
    var actions = SessionInspectorActions()
    /// False while the report is up over this page: its toolbar and the space
    /// bar then step aside.
    var isActive = true
    var isEditing = false
    /// Watch (false) or Edit (true) was picked in the toolbar.
    var onMode: (Bool) -> Void = { _ in }
    /// Where Back goes when the editor has no video to close.
    var onLeaveEdit: () -> Void = {}
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
    /// The transcript for Edit mode: click a sentence to cut it.
    @ViewBuilder let editTranscript: () -> Transcript

    private let gutter: CGFloat = 24
    private let headerHeight: CGFloat = 52
    private let toolsHeight: CGFloat = 36
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
            if isActive {
                SessionDetailToolbar(
                    model: model, actions: actions,
                    isEditing: isEditing, onMode: onMode,
                    canUndo: editor.canUndo, canRedo: editor.canRedo,
                    canSave: !editor.isExporting && editor.hasVideo && editor.hasUnsavedEdits,
                    onUndo: { editor.undo() }, onRedo: { editor.redo() },
                    onSave: { editor.showExportOptions = true },
                    onShare: { showShare.toggle() })
            }
        }
        // Space belongs to the editor's own key monitor while editing.
        .background(SpaceBarPlayback(active: isActive && hasVideo && !isEditing, onToggle: onTogglePlay))
        .popover(isPresented: $showShare, arrowEdge: .top) {
            SessionShareCard(model: model, actions: actions)
                .padding(16)
                .frame(width: 300)
        }
        .modifier(EditingSupport(isEditing: isEditing, chrome: chrome, onBack: onLeaveEdit))
        .onDeleteCommand { if !isEditing { actions.trash() } }
    }

    // MARK: Layouts

    private func wide(_ size: CGSize) -> some View {
        let column = size.width - SessionDetailRules.railWidth - gutter * 3
        let height = size.height - 20 - gutter
        return HStack(alignment: .top, spacing: gutter) {
            mainColumn(available: CGSize(width: column, height: height))
                .frame(width: max(0, column), height: max(0, height), alignment: .topLeading)
            sidePanel(fillsHeight: true, columnWidth: column)
                .frame(width: SessionDetailRules.railWidth, height: max(0, height))
        }
        .padding(.horizontal, gutter)
        .padding(.top, 20)
        .padding(.bottom, gutter)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func narrow(_ size: CGSize) -> some View {
        let width = size.width - gutter * 2
        let room = max(isEditing ? 520 : 220, size.height * (isEditing ? 0.9 : 0.55))
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                mainColumn(available: CGSize(width: width, height: room + headerHeight + gap * 2))
                sidePanel(fillsHeight: false, columnWidth: width)
            }
            .padding(.horizontal, gutter)
            .padding(.top, 20)
            .padding(.bottom, gutter)
            .frame(width: size.width, alignment: .topLeading)
        }
    }

    private var editAspect: CGFloat {
        editor.hasVideo ? SessionDetailRules.aspect(of: editor.displayVideoSize) : 16.0 / 9.0
    }

    /// The bar's block under the picture. Edit needs all of it (play row,
    /// filmstrip, lanes); Watch uses the top of it. The picture is sized
    /// against this in both modes, so it never moves or changes size.
    private var barBlockHeight: CGFloat { 210 }

    /// Header, picture, then the play row and the timeline right under it.
    private func mainColumn(available: CGSize) -> some View {
        let room = CGSize(width: available.width,
                          height: max(120, available.height - headerHeight - gap * 2 - barBlockHeight))
        // The shape comes from the recording itself in both modes (the editor
        // and the watch player read the same file), so the picture is the same.
        let shape = hasVideo ? aspect : (editor.hasVideo ? editAspect : 16.0 / 9.0)
        let fitted = SessionDetailRules.fit(aspect: shape, in: room)
        return VStack(alignment: .leading, spacing: gap) {
            header
                .frame(height: headerHeight, alignment: .topLeading)
            picture(fitted)
            Group {
                if isEditing {
                    EditTimelineBlock()
                } else {
                    timeline()
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(width: fitted.width, height: barBlockHeight, alignment: .topLeading)
        }
    }

    @ViewBuilder private func picture(_ size: CGSize) -> some View {
        Group {
            if isEditing { EditStage() } else { stage() }
        }
        .frame(width: size.width, height: size.height)
        .background(hasVideo || isEditing ? Color.black : Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            if hasVideo, !isEditing {
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
                if model.takes.count > 1, !isEditing { takeSwitch }
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

    // MARK: Right side

    @ViewBuilder private func sidePanel(fillsHeight: Bool, columnWidth: CGFloat) -> some View {
        if isEditing {
            EditSidePanel(transcriptHere: true, transcript: editTranscript)
                .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .top)
                .frame(height: fillsHeight ? nil : 520)
                .background(RailCardStyle.shape.fill(RailCardStyle.fill))
                .clipShape(RailCardStyle.shape)
        } else {
            rail(fillsHeight: fillsHeight)
        }
    }

    private func rail(fillsHeight: Bool) -> some View {
        VStack(spacing: 16) {
            SessionFeedbackLine(model: model, actions: actions)
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
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            work()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RailCardStyle.shape.fill(RailCardStyle.fill))
    }
}

/// Dialogs, sheets and the editor's keys, mounted only while editing.
private struct EditingSupport: ViewModifier {
    let isEditing: Bool
    @ObservedObject var chrome: EditorChrome
    var onBack: () -> Void

    func body(content: Content) -> some View {
        if isEditing {
            content.editorSupport(chrome: chrome, onBack: onBack)
        } else {
            content
        }
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
            #if DEBUG
            if let upload = model.upload { PostToThriveniButton(link: upload.url) }
            #endif
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

/// How it went as one line: what state it is in, and the one action for it.
struct SessionFeedbackLine: View {
    let model: SessionInspectorModel
    let actions: SessionInspectorActions

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("How it went").font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            action
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RailCardStyle.shape.fill(RailCardStyle.fill))
    }

    private var subtitle: String {
        switch model.analyse {
        case .unavailable(let why): return why
        case .ready(_, let leavesMac): return leavesMac ? "Not asked for yet. Leaves this Mac." : "Not asked for yet"
        case .running(let step, _, _): return step
        case .busy: return "Another session is being analysed."
        case .analysed(let engine, _, _): return model.summary ?? "Analysed \u{00B7} \(engine)"
        }
    }

    @ViewBuilder private var action: some View {
        switch model.analyse {
        case .ready:
            Button("Get feedback", action: actions.analyse).controlSize(.small)
        case .running:
            Button("Stop", role: .destructive, action: actions.stopAnalysis).controlSize(.small)
        case .analysed:
            Button(action: actions.openReport) {
                Text("Open").foregroundStyle(Brand.text)
            }
            .buttonStyle(.plain)
            .font(.callout.weight(.medium))
        default:
            EmptyView()
        }
    }
}
