//
//  SessionDetailContent.swift
//  Greenroom
//
//  A session's page as a drawing: the player large on the left with a marks
//  lane and a status strip under it, the work (Clips, Notes, Transcript,
//  Links) in an inspector on the right, and the actions in the window toolbar.
//
//  Like SessionsContent.swift this takes plain values and closures, and knows
//  nothing about the coordinator, the disk or AVKit: RecordingsView hands it
//  the player view, the lane's values and the tab content. DESIGN.md, "A
//  session's page"; .context/glass-audit.md section 2.
//
//  Kept from before: the picture and its marks lane never scroll away while
//  the tabs are used (2026-09-18), and the work sits beside the video, as the
//  Console's fixed column did.
//
import SwiftUI

extension SessionDetailRules {
    static func uploadTitle(_ state: SessionInspectorModel.YouTube) -> String {
        switch state {
        case .uploading: return uploadTitle(uploading: true, uploaded: false)
        case .uploaded: return uploadTitle(uploading: false, uploaded: true)
        default: return uploadTitle(uploading: false, uploaded: false)
        }
    }

    static func analyseTitle(_ state: SessionInspectorModel.Analyse,
                             progress: (index: Int, count: Int)?) -> String {
        switch state {
        case .running: return analyseTitle(running: true, analysed: false, progress: progress)
        case .analysed: return analyseTitle(running: false, analysed: true, progress: progress)
        default: return analyseTitle(running: false, analysed: false, progress: progress)
        }
    }
}

// MARK: - Toolbar

/// Take picker (2+ takes), then Upload, Analyse, Edit and the more menu, then
/// the inspector toggle. Upload and an agent's Analyse carry amber: they are
/// the two things here that can reach the network (DESIGN.md semantic colour).
struct SessionDetailToolbar: ToolbarContent {
    let model: SessionInspectorModel
    let actions: SessionInspectorActions
    @Binding var take: URL?
    @Binding var showWork: Bool
    var analyseProgress: (index: Int, count: Int)?
    var onToggleWork: () -> Void

    var body: some ToolbarContent {
        if model.takes.count > 1 {
            ToolbarItem(placement: .primaryAction) {
                Picker("Playing", selection: $take) {
                    ForEach(model.takes) { Text($0.label).tag(Optional($0.id)) }
                }
                .pickerStyle(.menu)
                .help("This session holds more than one recording or clip. Pick which one plays.")
            }
        }
        // Upload and Analyse are the actions that move or process the
        // recording; Edit and the more menu are their own group.
        ToolbarItemGroup(placement: .primaryAction) {
            uploadItem
            analyseItem
        }
        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            editItem
            moreMenu
        }
        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItem(placement: .primaryAction) {
            Button(action: onToggleWork) {
                Label(showWork ? "Hide work panel" : "Show work panel", systemImage: "sidebar.right")
            }
            .help(showWork ? "Hide Clips, Notes, Transcript and Links" : "Show Clips, Notes, Transcript and Links")
        }
    }

    /// Only the glyph carries amber; the label stays primary.
    private func amberGlyph(_ title: String, _ symbol: String, amber: Bool = true) -> some View {
        Label {
            Text(title).foregroundStyle(Color.primary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(amber ? Brand.net : Color.primary)
        }
    }

    // MARK: Upload

    @ViewBuilder private var uploadItem: some View {
        let title = SessionDetailRules.uploadTitle(model.youtube)
        switch model.youtube {
        case .noVideo:
            Button {} label: { Label(title, systemImage: "square.and.arrow.up") }
                .labelStyle(.titleAndIcon)
                .disabled(true)
                .help("This session has no recording.")
        case .notConnected:
            Button {} label: { amberGlyph(title, "square.and.arrow.up") }
            .labelStyle(.titleAndIcon)
            .disabled(true)
            .help("Connect a YouTube channel in Settings \u{2192} YouTube first. Uploading sends the recording off this Mac.")
        case .ready(let privacy):
            Button(action: actions.upload) { amberGlyph(title, "square.and.arrow.up") }
            .labelStyle(.titleAndIcon)
            .help("Uploads this recording to the connected channel as \(privacy). It leaves this Mac.")
        case .uploading:
            Button {} label: {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(title)
                }
            }
            .disabled(true)
            .help("Uploading to YouTube. It leaves this Mac.")
        case .uploaded:
            Menu {
                Button("Open on YouTube", action: actions.openOnYouTube)
                Button("Copy link", action: actions.copyLink)
                Button("Rename on YouTube\u{2026}", action: actions.renameOnYouTube)
                Button("Upload again", action: actions.upload)
                    .disabled(!model.youtubeConnected)
                if model.youtubeConnected {
                    Divider()
                    Button("Delete from YouTube\u{2026}", role: .destructive, action: actions.deleteFromYouTube)
                }
            } label: {
                amberGlyph(title, "checkmark.circle.fill")
            }
            .labelStyle(.titleAndIcon)
            .help("On YouTube. Open, copy the link, rename, or delete it.")
        }
    }

    // MARK: Analyse

    @ViewBuilder private var analyseItem: some View {
        let title = SessionDetailRules.analyseTitle(model.analyse, progress: analyseProgress)
        switch model.analyse {
        case .unavailable(let why):
            Button {} label: { Label(title, systemImage: "sparkles") }
                .labelStyle(.titleAndIcon)
                .disabled(true)
                .help(why)
        case .busy:
            Button {} label: { Label(title, systemImage: "sparkles") }
                .labelStyle(.titleAndIcon)
                .disabled(true)
                .help("One analysis at a time. This one can start when the other finishes.")
        case .ready(_, let leavesMac):
            Menu {
                Button("How to analyse\u{2026}", action: actions.openAnalysisSetup)
            } label: {
                amberGlyph(title, "sparkles", amber: leavesMac)
            } primaryAction: {
                actions.analyse()
            }
            .labelStyle(.titleAndIcon)
            .help(leavesMac
                  ? "Transcribes on this Mac, then sends the transcript and notes to the agent chosen under How to analyse. That part leaves this Mac; the video does not."
                  : "Transcribes on this Mac, counts pace and filler words, and writes the report. Nothing leaves this Mac.")
        case .running(let step, let detail, _):
            Menu {
                Text(step)
                if !detail.isEmpty { Text(detail) }
                Divider()
                Button("Stop analysis", role: .destructive, action: actions.stopAnalysis)
            } label: {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(title)
                }
            }
            .help("Running. Open the menu to stop it. Nothing is written until it finishes.")
        case .analysed(_, _, let leavesMac):
            Menu {
                Button("Analyse again", action: actions.analyse)
                Button("How to analyse\u{2026}", action: actions.openAnalysisSetup)
            } label: {
                amberGlyph(title, "sparkles", amber: leavesMac)
            } primaryAction: {
                actions.openReport()
            }
            .labelStyle(.titleAndIcon)
            .help("Opens the full report.")
        }
    }

    // MARK: Edit, more

    @ViewBuilder private var editItem: some View {
        Button(action: actions.edit) {
            Label("Edit", systemImage: "scissors")
        }
        .labelStyle(.titleAndIcon)
        .disabled(!model.canEdit)
        .help(model.canEdit
              ? "Opens this recording in the editor. Saving makes a new recording and leaves this one untouched."
              : "No recording to edit.")
    }

    private var moreMenu: some View {
        Menu {
            Button("Rename\u{2026}", action: actions.rename)
                .disabled(!model.canRename)
            Button("Show in Finder", action: actions.showInFinder)
            Divider()
            Button("Move to Trash\u{2026}", role: .destructive, action: actions.trash)
                .disabled(!model.canTrash)
        } label: {
            Label("More", systemImage: "ellipsis.circle")
                .foregroundStyle(Color.primary)
        }
        .menuIndicator(.hidden)
        .tint(nil)
        .help("Rename, show in Finder, or move to the Trash")
    }
}

// MARK: - Page

/// Player column plus inspector. The stage, the lane and the tab content come
/// in as views; this owns the layout, the toolbar and the fold rule.
struct SessionDetailPage<Stage: View, Lane: View, Work: View>: View {
    let model: SessionInspectorModel
    var actions = SessionInspectorActions()
    var analyseProgress: (index: Int, count: Int)?
    /// False while the report is up over this page: its toolbar and subtitle
    /// then step aside.
    var isActive = true
    @Binding var take: URL?
    let tabs: [String]
    @Binding var tab: String
    @ViewBuilder let stage: () -> Stage
    @ViewBuilder let lane: () -> Lane
    @ViewBuilder let work: () -> Work

    @State private var showWork = true
    @State private var foldedByWidth = false

    var body: some View {
        GeometryReader { geo in
            playerColumn
                .inspector(isPresented: $showWork) {
                    inspectorColumn
                        .inspectorColumnWidth(min: 300, ideal: 340, max: 480)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .onChange(of: geo.size.width, initial: true) { _, width in
                    let next = SessionDetailRules.inspector(width: width, shown: showWork,
                                                            foldedByWidth: foldedByWidth)
                    showWork = next.shown
                    foldedByWidth = next.foldedByWidth
                }
        }
        .toolbar {
            if isActive {
                SessionDetailToolbar(model: model, actions: actions, take: $take,
                                     showWork: $showWork, analyseProgress: analyseProgress,
                                     onToggleWork: {
                                         // A person's choice beats the width rule.
                                         foldedByWidth = false
                                         showWork.toggle()
                                     })
            }
        }
        // Subtitle from a background so the page's own identity never changes
        // when it steps aside.
        .background {
            if isActive { Color.clear.navigationSubtitle(model.meta) }
        }
        .onDeleteCommand(perform: actions.trash)
    }

    /// Picture, marks lane, status strip. None of it scrolls: the picture and
    /// its lane stay on screen while the tabs are used.
    private var playerColumn: some View {
        VStack(spacing: 0) {
            stage()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 200)
                .background(Color.black)
                .clipped()
                .layoutPriority(0)
            VStack(alignment: .leading, spacing: 8) {
                lane()
                SessionStatusStrip(model: model, actions: actions)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
        }
        .frame(minWidth: 480)
    }

    private var inspectorColumn: some View {
        // No painted background: the system inspector draws its own material.
        VStack(spacing: 0) {
            if !tabs.isEmpty {
                GreenroomSegmented("Work", selection: $tab, options: tabs) { Text($0) }
                    .controlSize(.small)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                Divider()
            }
            // GeometryReader so the work's own ideal height never reaches the
            // split view, which sized itself to it (about 1700pt) and pushed
            // the page's top and bottom edges off the window.
            GeometryReader { g in
                work()
                    .frame(width: g.size.width, height: g.size.height, alignment: .top)
            }
        }
    }
}

// MARK: - Status strip

/// What happened to this session, one line each, under the marks lane.
/// Replaces the Upload and Analyse tiles, "How to analyse" and the upload
/// link line. Amber (`Brand.netText`) marks what is on YouTube.
struct SessionStatusStrip: View {
    let model: SessionInspectorModel
    let actions: SessionInspectorActions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            analysisLine
            uploadLine
        }
        .font(.callout)
    }

    @ViewBuilder private var analysisLine: some View {
        switch model.analyse {
        case .running(let step, let detail, let log):
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(Brand.text)
                    Text(step).lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail).foregroundStyle(.secondary).lineLimit(1)
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
            }
        case .analysed(let engine, let when, _):
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(Brand.text)
                    Text("Analysed \u{00B7} \(engine) \u{00B7} \(when.formatted(.relative(presentation: .named)))")
                        .lineLimit(1)
                    if let summary = model.summary {
                        Text("\u{2014} \u{201C}\(summary)\u{201D}")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    Button(action: actions.openReport) {
                        Text("Open report \u{2192}").foregroundStyle(Brand.text)
                    }
                    .buttonStyle(.plain)
                }
                if let caveat = model.summaryCaveat {
                    Text(caveat).font(.caption).foregroundStyle(.secondary)
                }
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var uploadLine: some View {
        if let upload = model.upload {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.up").foregroundStyle(Brand.netText)
                Text("On YouTube \u{00B7} \(upload.privacy.capitalized)")
                    .foregroundStyle(Brand.netText)
                    .lineLimit(1)
                Text(upload.url)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button("Copy", action: actions.copyLink)
                Button("Open", action: actions.openOnYouTube)
            }
            .buttonStyle(.link)
            .help("\u{201C}\(upload.title)\u{201D}, uploaded \(upload.uploadedAt.formatted(date: .abbreviated, time: .shortened))")
        }
    }
}

// MARK: - Marks lane

/// The marked moments drawn against the whole recording. Not a scrubber: the
/// player has the one scrubber. A click on the lane, a clip block or a note
/// jumps there; nothing drags.
struct SessionMarksLane: View {
    /// Screenroom's moments, in seconds: fillers as short ticks, notes tall.
    struct Marks {
        var fillers: [Double] = []
        var notes: [Double] = []
        var isEmpty: Bool { fillers.isEmpty && notes.isEmpty }
    }

    let duration: Double
    let playhead: Double
    let clips: [SessionClip]
    var marks = Marks()
    var skipping = false
    var onStopSkipping: () -> Void = {}
    let onSeek: (Double) -> Void

    private let laneHeight: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.18))
                        .frame(height: laneHeight)

                    if duration > 0 {
                        ForEach(clips) { clip in
                            let start = SessionDetailRules.fraction(of: clip.startSeconds, in: duration)
                            let span = max(0.004, Double(clip.durationMs) / 1000 / duration)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.accentColor.opacity(0.75))
                                .frame(width: max(3, width * span), height: laneHeight)
                                .offset(x: width * start)
                                .onTapGesture { onSeek(clip.startSeconds) }
                                .help("\(clip.durationLabel), marked at \(clip.markedAtLabel.replacingOccurrences(of: "-", with: ":"))")
                        }
                        ForEach(Array(marks.fillers.enumerated()), id: \.offset) { _, at in
                            Capsule()
                                .fill(Brand.fill)
                                .frame(width: 2, height: 9)
                                .offset(x: width * SessionDetailRules.fraction(of: at, in: duration) - 1, y: 6)
                                .allowsHitTesting(false)
                        }
                        ForEach(Array(marks.notes.enumerated()), id: \.offset) { _, at in
                            Capsule()
                                .fill(Color.primary.opacity(0.75))
                                .frame(width: 3, height: laneHeight)
                                .offset(x: width * SessionDetailRules.fraction(of: at, in: duration) - 1.5)
                                .onTapGesture { onSeek(max(0, at - 4)) }
                                .help("A note")
                        }
                        // Where the player is: a hairline, not a handle.
                        Rectangle()
                            .fill(Color.primary.opacity(0.6))
                            .frame(width: 1, height: laneHeight + 6)
                            .offset(x: width * SessionDetailRules.fraction(of: playhead, in: duration))
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: laneHeight + 6)
                .contentShape(Rectangle())
                .onTapGesture { point in
                    if let time = SessionDetailRules.seekTime(x: point.x, width: width, duration: duration) {
                        onSeek(time)
                    }
                }
            }
            .frame(height: laneHeight + 6)
            .help("Marked clips and notes. Click one to jump there.")
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Marked clips and notes")

            if skipping {
                HStack(spacing: 6) {
                    Text("Playing without fillers")
                    Button("Stop", action: onStopSkipping).buttonStyle(.link)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            } else if !marks.isEmpty {
                Text(markLegend)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var markLegend: String {
        var parts: [String] = []
        if !marks.fillers.isEmpty { parts.append("short ticks: \(marks.fillers.count) filler\(marks.fillers.count == 1 ? "" : "s")") }
        if !marks.notes.isEmpty { parts.append("tall: \(marks.notes.count) note\(marks.notes.count == 1 ? "" : "s")") }
        return parts.joined(separator: " \u{00B7} ")
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
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
