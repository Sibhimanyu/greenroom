// Ported from Recorditor (ZRecorditor @7210322, native/MacRecorder/Editor/EditorView.swift).
//
// Reworked: the editor is not a page of its own any more. It is the Edit mode
// of a session's page (SessionDetailContent.swift), so this file holds the
// editor's PARTS and the page lays them out around the picture and timeline
// that Watch mode shares:
//
//   EditStage          the picture: the editor's player, crop, blur, text and
//                      arrow overlays, the status toast and the saving card
//   EditToolRow        the tools under the picture (Cut, Trim, Blur, ...)
//   EditTimelineBlock  the transport row and the opened-up timeline
//   EditSidePanel      "Your edits" (and the transcript when it has no room
//                      beside the picture)
//   EditorSupport      what hangs off the whole page while editing: the Save
//                      sheet, the discard question, the saved card, the keys
import AppKit
import SwiftUI

/// State the edit parts share, kept out of the views so the page can build
/// them in different places.
@MainActor
final class EditorChrome: ObservableObject {
    @Published var showDiscardConfirm = false
    @Published var savedPlaybackURL: URL?
    let keyMonitor = EditorKeyMonitor()
}

/// Everything that belongs to the page while it is in Edit mode but is not a
/// region of it. Applied once, to the page, only while editing.
struct EditorSupport: ViewModifier {
    @EnvironmentObject private var vm: EditorViewModel
    @ObservedObject var chrome: EditorChrome
    /// Where Back goes when no video is loaded (a loaded one closes itself,
    /// and the page follows).
    var onBack: () -> Void = {}

    func body(content: Content) -> some View {
        content
            .overlay {
                if let saved = vm.savedExportURL {
                    EditorSavedPopup(url: saved, chrome: chrome)
                }
            }
            .sheet(isPresented: $vm.showExportOptions) {
                ExportOptionsSheet()
                    .environmentObject(vm)
            }
            .sheet(isPresented: Binding(get: { chrome.savedPlaybackURL != nil },
                                        set: { if !$0 { chrome.savedPlaybackURL = nil } })) {
                if let url = chrome.savedPlaybackURL {
                    EditorPlaybackSheet(url: url, title: url.lastPathComponent)
                }
            }
            .confirmationDialog("Discard your edits?", isPresented: $chrome.showDiscardConfirm) {
                Button("Keep Editing", role: .cancel) {}
                Button("Discard", role: .destructive) { vm.closeVideo() }
                Button("Save\u{2026}") { vm.showExportOptions = true }
            } message: {
                Text("Your trims, removed stretches, effects and extra clips will be lost unless you save them first.")
            }
            // Back (the page's button, \u{2318}[, Esc, or the Watch switch)
            // arrives here as a request.
            .onChange(of: vm.backRequests) { _, _ in handleBack() }
            .onAppear { chrome.keyMonitor.install(vm: vm) }
            .onDisappear { chrome.keyMonitor.remove() }
    }

    private func handleBack() {
        guard !vm.isExporting, vm.savedExportURL == nil else { return }
        if !vm.hasVideo {
            onBack()
        } else if vm.hasUnsavedEdits {
            chrome.showDiscardConfirm = true
        } else {
            vm.closeVideo()
        }
    }
}

extension View {
    func editorSupport(chrome: EditorChrome, onBack: @escaping () -> Void) -> some View {
        modifier(EditorSupport(chrome: chrome, onBack: onBack))
    }
}

/// Post-save card over the page: the edit is its own new recording in the
/// library, one click re-opens it for further edits.
struct EditorSavedPopup: View {
    @EnvironmentObject private var vm: EditorViewModel
    let url: URL
    @ObservedObject var chrome: EditorChrome

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .onTapGesture { vm.savedExportURL = nil }
            VStack(spacing: 16) {
                ZStack {
                    Circle().fill(Brand.green.opacity(0.15)).frame(width: 72, height: 72)
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Brand.green)
                }
                Text("Saved \(url.lastPathComponent)")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("It's in your Recordings, ready to share.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        chrome.savedPlaybackURL = url
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    Button {
                        // Load first: clearing the popup with nothing loaded
                        // reads as "editor closed" and leaves the page.
                        Task {
                            await vm.load(url: url)
                            vm.savedExportURL = nil
                        }
                    } label: {
                        Label("Edit Exported Video", systemImage: "slider.horizontal.3")
                    }
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                        vm.savedExportURL = nil
                    } label: {
                        Label("Finder", systemImage: "folder")
                    }
                    Button {
                        vm.savedExportURL = nil
                    } label: {
                        Text("Done")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.green)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(30)
            .frame(maxWidth: 460)
            .greenroomGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .transition(.opacity)
    }
}

// MARK: - The picture

/// The editor's picture. It fills whatever frame the page gives it; the page
/// owns the size, the clip and the background.
struct EditStage: View {
    @EnvironmentObject private var vm: EditorViewModel

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if vm.hasVideo {
                    PlayerContainerView(player: vm.player)
                    if vm.isCropping {
                        CropOverlayView(containerSize: geo.size)
                    }
                    AnnotationPreviewOverlay(containerSize: geo.size)
                    if abs(vm.activePreviewRate - 1) > 0.01 {
                        VStack {
                            HStack {
                                Spacer()
                                Label(String(format: "%g\u{00D7}", vm.activePreviewRate),
                                      systemImage: vm.activePreviewRate < 1 ? "tortoise.fill" : "hare.fill")
                                    .font(.callout.bold())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.black.opacity(0.65), in: Capsule())
                                    .padding(10)
                            }
                            Spacer()
                        }
                        .allowsHitTesting(false)
                    }
                    if vm.pendingAnnotationKind != nil {
                        AnnotationPlacementOverlay(containerSize: geo.size)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // Status toast floats over the picture: messages at the bottom of
            // a scrolling panel went unseen.
            .overlay(alignment: .top) { messageToast }
            // Saving takes a while (two encode passes with effects): make the
            // progress impossible to miss.
            .overlay {
                if vm.isExporting {
                    ZStack {
                        Color.black.opacity(0.55)
                        VStack(spacing: 14) {
                            ProgressView(value: vm.exportProgress)
                                .progressViewStyle(.circular)
                                .controlSize(.large)
                            Text("Saving\u{2026} \(Int(vm.exportProgress * 100))%")
                                .font(.title3.weight(.semibold))
                            Text("Your edits are being put into the video.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Cancel") { vm.cancelExport() }
                        }
                        .padding(28)
                        .greenroomGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    @ViewBuilder
    private var messageToast: some View {
        if let message = vm.errorMessage ?? vm.exportMessage {
            let isError = vm.errorMessage != nil
            HStack(spacing: 8) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isError ? EditorTheme.danger : Brand.green)
                Text(message)
                    .font(.callout)
                    .lineLimit(3)
                Button {
                    vm.errorMessage = nil
                    vm.exportMessage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .greenroomGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke((isError ? EditorTheme.danger : Brand.green).opacity(0.5), lineWidth: 1))
            .padding(.top, 10)
            .frame(maxWidth: 560)
            .transition(.move(edge: .top).combined(with: .opacity))
            // Successes fade on their own; errors stay until dismissed.
            .task(id: message) {
                guard !isError else { return }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if vm.exportMessage == message { vm.exportMessage = nil }
            }
        }
    }
}

// MARK: - Tools under the picture

/// Cut, Trim, Blur, Text, Arrow, Crop, Speed, More: ranked by how often they
/// are the next thing a teacher wants. Tools act on the picked stretch if
/// there is one, else at the playhead.
struct EditToolRow: View {
    @EnvironmentObject private var vm: EditorViewModel
    @StateObject private var library = EditorRecordingLibrary()
    @State private var showMergeSource = false
    @State private var showSpeed = false

    var body: some View {
        toolButtons
            .fixedSize()
    }

    /// Trim, Cut and Blur up front; Text, Arrow, Crop, Speed, Join and the
    /// audio under More. (Make clip is a session action, not built here.)
    private var toolButtons: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Start here") { vm.setTrimStartToPlayhead() }
                Button("End here") { vm.setTrimEndToPlayhead() }
                if vm.trimIsSet {
                    Divider()
                    if vm.trimStart > 0.05 { Button("Reset the start") { vm.resetTrimStart() } }
                    if vm.trimEnd < vm.duration - 0.05 { Button("Reset the end") { vm.resetTrimEnd() } }
                }
            } label: {
                Label("Trim", systemImage: "arrow.left.and.right.square")
            }
            .menuStyle(.button)
            .fixedSize()
            .help("Cut the start or the end of the video at the playhead. Or drag the edges of the timeline.")

            Button {
                vm.removeSelection()
            } label: {
                Label("Cut", systemImage: "scissors")
            }
            .fixedSize()
            .disabled(vm.selection == nil)
            .help(vm.selection == nil
                  ? "Drag across the timeline to pick a stretch, then cut it out"
                  : "Take the picked stretch out of the video (\u{232B})")

            Button {
                vm.beginAnnotationPlacement(.blur)
            } label: {
                Label("Blur", systemImage: "eye.slash")
            }
            .fixedSize()
            .help("Hide something on screen. Drag over the video after choosing.")

            Menu {
                Button("Text") { vm.beginAnnotationPlacement(.text) }
                Button("Arrow") { vm.beginAnnotationPlacement(.arrow) }
                Button(vm.isCropping ? "Done Cropping" : "Crop") { vm.isCropping.toggle() }
                Button("Speed\u{2026}") { showSpeed = true }
                Divider()
                Button("Join Videos\u{2026}") { showMergeSource = true }
                Button(vm.overlayAudioURL == nil ? "Background Audio\u{2026}" : "Change Background Audio\u{2026}") {
                    vm.addAudioPanel()
                }
                Button("Open Another Video\u{2026}") { vm.openVideoPanel() }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.button)
            .fixedSize()
            .popover(isPresented: $showMergeSource, arrowEdge: .top) {
                mergeSourcePopover(isPresented: $showMergeSource)
            }
            .background(
                Color.clear
                    .popover(isPresented: $showSpeed, arrowEdge: .top) {
                        SpeedPopover(isPresented: $showSpeed)
                            .environmentObject(vm)
                    })
            .help("Text, Arrow, Crop, Speed, join videos, background audio")
        }
    }

    /// Shared "add videos to merge" popover: Browse Files… pinned at the top
    /// (never scrolls away), every library recording below it in a scroll.
    private func mergeSourcePopover(isPresented: Binding<Bool>) -> some View {
        VStack(spacing: 0) {
            Button {
                isPresented.wrappedValue = false
                vm.addMergeClipPanel()
            } label: {
                Label("Browse Files…", systemImage: "folder.fill")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !library.items.isEmpty {
                Divider()
                Text("Your Recordings")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(library.items) { item in
                            Button {
                                isPresented.wrappedValue = false
                                vm.addMergeClips(urls: [item.url])
                            } label: {
                                HStack(spacing: 8) {
                                    EditorRecordingThumb(url: item.url)
                                    .frame(width: 56, height: 32)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    Text(item.name)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 6)
                                    EditorRecordingDuration(url: item.url)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 6)
                }
                .frame(height: 320)
            }
        }
        .frame(width: 400)
        .padding(.vertical, 6)
        // The library is only refreshed by the editor's empty state — coming
        // straight from a recording it would still be empty here.
        .task { library.refresh() }
    }
}

// MARK: - Transport and timeline

/// Play, the time, and the opened-up timeline: the same place on the page as
/// Watch mode's one timeline, with room for the filmstrip and the lanes.
struct EditTimelineBlock: View {
    @EnvironmentObject private var vm: EditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            transport
            // Natural height up to the block's frame; past it the lanes
            // scroll rather than push the picture off the page.
            ViewThatFits(in: .vertical) {
                EditorTimelineView()
                ScrollView(.vertical, showsIndicators: true) { EditorTimelineView() }
            }
        }
    }

    private var hint: String {
        guard let selection = vm.selection else { return "Drag across the timeline to pick a stretch" }
        return "Picked \(SessionDetailRules.clock(selection.lowerBound)) to \(SessionDetailRules.clock(selection.upperBound))"
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button {
                vm.togglePlay()
            } label: {
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(vm.isPlaying ? "Pause (Space)" : "Play (Space)")
            .accessibilityLabel(vm.isPlaying ? "Pause" : "Play")

            Text(SessionDetailRules.clock(vm.playhead))
                .font(.system(size: 12, design: .monospaced))
                .monospacedDigit()
                .fixedSize()
            Text("/ \(SessionDetailRules.clock(vm.timelineDuration))")
                .font(.system(size: 12, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()

            EditToolRow()

            if let index = vm.playingMergeIndex {
                Text("Extra clip \(index + 1)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.text)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Brand.green.opacity(0.15)))
                    .fixedSize()
            }

            Spacer(minLength: 0)

            if vm.isExporting {
                ProgressView(value: vm.exportProgress)
                    .frame(width: 120)
                Text("\(Int(vm.exportProgress * 100))%")
                    .font(.caption.monospaced())
                Button("Cancel") { vm.cancelExport() }
                    .controlSize(.small)
                    .help("Stop saving. No file is made.")
            } else {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
            }
        }
        .frame(height: 32)
    }
}

// MARK: - Side panel

/// "Your edits", and, when the transcript has no room beside the picture, a
/// second tab for it.
struct EditSidePanel<Transcript: View>: View {
    var transcriptHere: Bool
    @ViewBuilder let transcript: () -> Transcript
    @State private var tab = "Edits"

    var body: some View {
        VStack(spacing: 0) {
            if transcriptHere {
                GreenroomSegmented("Side", selection: $tab, options: ["Edits", "Transcript"]) { Text($0) }
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 4)
            }
            if transcriptHere, tab == "Transcript" {
                transcript()
            } else {
                EditsPanel()
            }
        }
    }
}

/// The list of what has been done, each row a way back to it, and the two
/// lengths: the original, and what Save will make.
struct EditsPanel: View {
    @EnvironmentObject private var vm: EditorViewModel
    @State private var showAudioOptions = false
    @StateObject private var library = EditorRecordingLibrary()

    var body: some View {
        VStack(spacing: 0) {
            Text("YOUR EDITS")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 14)
            editsPanel
            footer
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            lengthRow("Original", vm.duration)
            lengthRow("After edits", vm.editedDuration, strong: true)
            Text("Save makes a new recording. The original file stays as it is.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }

    private func lengthRow(_ label: String, _ seconds: Double, strong: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(strong ? Color.primary : Color.secondary)
            Spacer(minLength: 8)
            Text(SessionDetailRules.clock(seconds))
                .font(.system(size: 13, weight: strong ? .semibold : .regular, design: .monospaced))
                .monospacedDigit()
                .fixedSize()
        }
    }

    /// Full background-audio controls: the slice of the file to use,
    /// looping, and volume.
    private func audioOptionsPopover(name: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(name, systemImage: "music.note")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("USE THIS PART OF THE AUDIO")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                HStack {
                    Text("From \(TimeFormatting.clock(vm.overlayAudioClipStart))")
                        .font(.caption.monospaced())
                        .frame(width: 90, alignment: .leading)
                    Slider(value: $vm.overlayAudioClipStart,
                           in: 0...max(0.5, vm.overlayAudioClipEnd - 0.5))
                }
                HStack {
                    Text("To \(TimeFormatting.clock(vm.overlayAudioClipEnd))")
                        .font(.caption.monospaced())
                        .frame(width: 90, alignment: .leading)
                    Slider(value: $vm.overlayAudioClipEnd,
                           in: min(vm.overlayAudioClipStart + 0.5, vm.overlayAudioDuration)...max(vm.overlayAudioDuration, 0.5))
                }
                Text("Selected: \(TimeFormatting.clock(vm.overlayClipLength)) of \(TimeFormatting.clock(vm.overlayAudioDuration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Fade in and out", isOn: $vm.overlayAudioFades)
                .help("Ease the audio in at its start and out at its end")
            Toggle("Repeat until the video ends", isOn: $vm.overlayAudioLoops)
                .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 6) {
                Text("VOLUME")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                Slider(value: $vm.overlayAudioVolume, in: 0...1)
            }

            Text("Starts in the video at \(TimeFormatting.clock(vm.overlayAudioStart)) — drag the green bar under the timeline to move it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: Edits panel

    private var hasAnyEdit: Bool {
        vm.trimIsSet || !vm.cuts.isEmpty || !vm.annotations.isEmpty || !vm.speedSegments.isEmpty
            || vm.cropRect != nil || !vm.mergeClips.isEmpty || vm.overlayAudioURL != nil
    }

    private var editsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !hasAnyEdit {
                    emptyEditsHint
                }

                if vm.trimIsSet {
                    panelSection("TRIM") {
                        if vm.trimStart > 0.05 {
                            trimRow("Start", time: vm.trimStart) { vm.resetTrimStart() }
                        }
                        if vm.trimEnd < vm.duration - 0.05 {
                            trimRow("End", time: vm.trimEnd) { vm.resetTrimEnd() }
                        }
                    }
                }

                if !vm.cuts.isEmpty {
                    panelSection("REMOVED STRETCHES") {
                        ForEach(vm.cuts) { cut in
                            editRow(selected: vm.selectedCutID == cut.id,
                                    onTap: { vm.selectedCutID = cut.id; vm.selection = nil; vm.seek(to: cut.start) },
                                    onRemove: { vm.deleteCut(id: cut.id) }) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(TimeFormatting.clock(cut.start)) → \(TimeFormatting.clock(cut.end))")
                                        .font(.system(.callout, design: .monospaced))
                                    Text("\(TimeFormatting.spoken(cut.duration)) removed")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if !vm.annotations.isEmpty {
                    panelSection("BLUR, TEXT AND ARROWS") {
                        ForEach($vm.annotations) { $annotation in
                            editRow(selected: vm.selectedAnnotationID == annotation.id,
                                    onTap: { vm.selectedAnnotationID = annotation.id; vm.seek(to: annotation.start) },
                                    onRemove: { vm.removeAnnotation(id: annotation.id) }) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Image(systemName: annotation.kind == .blur ? "eye.slash"
                                              : annotation.kind == .text ? "textformat" : "arrow.up.right")
                                            .foregroundStyle(Brand.text)
                                        Text("\(TimeFormatting.clock(annotation.start)) – \(TimeFormatting.clock(annotation.end))")
                                            .font(.caption.monospaced())
                                    }
                                    if annotation.kind == .text {
                                        TextField("Text", text: $annotation.text)
                                            .textFieldStyle(.greenroom)
                                            .font(.caption)
                                    }
                                }
                            }
                        }
                    }
                }

                if !vm.speedSegments.isEmpty {
                    panelSection("SPEED") {
                        ForEach(vm.speedSegments) { segment in
                            editRow(selected: vm.selectedSpeedID == segment.id,
                                    onTap: { vm.selectedSpeedID = segment.id; vm.seek(to: segment.start) },
                                    onRemove: { vm.removeSpeedSegment(id: segment.id) }) {
                                HStack(spacing: 6) {
                                    Text(String(format: "%g×", segment.factor))
                                        .font(.caption.bold())
                                    Text("\(TimeFormatting.clock(segment.start)) – \(TimeFormatting.clock(segment.end))")
                                        .font(.caption.monospaced())
                                }
                            }
                        }
                    }
                }

                if let crop = vm.cropRect {
                    panelSection("CROP") {
                        editRow(selected: false, onTap: { vm.isCropping = true },
                                onRemove: { vm.setCrop(nil) }) {
                            Text("\(Int(crop.width * vm.videoSize.width)) × \(Int(crop.height * vm.videoSize.height)) px")
                                .font(.system(.callout, design: .monospaced))
                        }
                    }
                }

                if !vm.mergeClips.isEmpty {
                    panelSection("EXTRA CLIPS") {
                        Text("Joined after this video, in this order.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(Array(vm.mergeClips.enumerated()), id: \.element.id) { index, clip in
                            mergeClipRow(index: index, clip: clip)
                        }
                    }
                }

                if let audioURL = vm.overlayAudioURL {
                    panelSection("AUDIO") {
                        let name = audioURL.deletingPathExtension().lastPathComponent
                        editRow(selected: false, onTap: { showAudioOptions = true },
                                onRemove: { vm.overlayAudioURL = nil }) {
                            VStack(alignment: .leading, spacing: 2) {
                                Label(name, systemImage: "music.note")
                                    .font(.callout)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text("Starts at \(TimeFormatting.clock(vm.overlayAudioStart)). Click for options.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .popover(isPresented: $showAudioOptions, arrowEdge: .leading) {
                            audioOptionsPopover(name: name)
                        }
                        HStack {
                            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                            Slider(value: $vm.overlayAudioVolume, in: 0...1)
                        }
                        .help("Background audio volume")
                    }
                }

                if vm.hasRecordedEvents {
                    panelSection("RECORDED CLICKS AND KEYS") {
                        Toggle("Click ripples", isOn: $vm.showClickRipples)
                            .help("Show a ripple wherever you clicked while recording")
                        Toggle("Keystrokes", isOn: $vm.showKeystrokes)
                            .help("Show the keys you pressed on screen")
                        Toggle("Auto zoom", isOn: $vm.autoZoom)
                            .help("Zoom in around your clicks")
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                Text(infoLine)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, 4)
            }
            .padding(14)
            .animation(.snappy(duration: 0.2), value: hasAnyEdit)
        }
    }

    private var infoLine: String {
        "\(Int(vm.videoSize.width)) × \(Int(vm.videoSize.height)) · \(vm.fileSizeText)"
    }

    private var emptyEditsHint: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nothing edited yet")
                .font(.headline)
            hintRow("arrow.left.and.right", "Drag the edges of the bar to trim the start or end.")
            hintRow("rectangle.dashed", "Drag across the bar to select a stretch, then remove it, speed it up or blur it.")
            hintRow("text.quote", "Click a sentence in the transcript to cut it out.")
            hintRow("cursorarrow.click", "Click the bar to jump to that moment.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func hintRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Brand.text)
                .frame(width: 18)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func trimRow(_ label: String, time: Double, reset: @escaping () -> Void) -> some View {
        editRow(selected: false, onTap: { vm.seek(to: time) }, onRemove: reset) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Text(TimeFormatting.clock(time))
                    .font(.system(.callout, design: .monospaced))
            }
            .font(.callout)
        }
    }

    private func mergeClipRow(index: Int, clip: MergeClip) -> some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.caption.bold().monospaced())
                .foregroundStyle(Brand.text)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Brand.green.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.url.lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(clip.isTrimmed
                     ? "\(TimeFormatting.clock(clip.trimmedDuration)) of \(TimeFormatting.clock(clip.duration)) (trimmed)"
                     : TimeFormatting.clock(clip.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(spacing: 2) {
                Button {
                    vm.moveMergeClip(id: clip.id, up: true)
                } label: {
                    Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(index == 0 ? .quaternary : .secondary)
                .disabled(index == 0)
                .help("Move this clip earlier")
                Button {
                    vm.moveMergeClip(id: clip.id, up: false)
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(index == vm.mergeClips.count - 1 ? .quaternary : .secondary)
                .disabled(index == vm.mergeClips.count - 1)
                .help("Move this clip later")
            }
            Button {
                vm.removeMergeClip(id: clip.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Take this clip out")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    /// One row of the Edits list: tap to jump to it, x to take it away.
    private func editRow<Content: View>(selected: Bool,
                                        onTap: @escaping () -> Void,
                                        onRemove: @escaping () -> Void,
                                        @ViewBuilder content: () -> Content) -> some View {
        HStack {
            content()
            Spacer(minLength: 6)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove this edit")
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Brand.green.opacity(0.16) : Color.secondary.opacity(0.08)))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? Brand.green.opacity(0.6) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    private func panelSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            EditorPanelHeader(title: title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .editorCard(padding: 12, cornerRadius: 10)
    }
}

/// Speed for a stretch: the selection if there is one, else the playhead plus
/// ten seconds. Also offered for the whole video.
struct SpeedPopover: View {
    @EnvironmentObject private var vm: EditorViewModel
    @Binding var isPresented: Bool
    @State private var factor: Double = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SPEED")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            // Custom control: AppKit-backed Slider rendered broken on the
            // popover's first layout pass, whatever its configuration.
            SpeedDial(value: $factor)
            HStack {
                Text("0.25×").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("8×").font(.caption2).foregroundStyle(.secondary)
            }
            if vm.mergeClips.isEmpty {
                let span = vm.toolSpan(defaultLength: 10)
                Text(vm.selection == nil
                     ? "From the playhead, \(TimeFormatting.clock(span.0)) to \(TimeFormatting.clock(span.1)). Select a stretch first to choose your own."
                     : "For your selection, \(TimeFormatting.clock(span.0)) to \(TimeFormatting.clock(span.1)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button {
                        vm.applySpeedToSelection(factor: factor)
                        isPresented = false
                    } label: {
                        Text(String(format: "Apply %g×", factor))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.green)
                    .disabled(abs(factor - 1) < 0.01)
                    Button("Whole video") {
                        vm.applySpeedToWholeVideo(factor: factor)
                        isPresented = false
                    }
                    .disabled(abs(factor - 1) < 0.01)
                }
                Text("Below 1× is slow motion. The saved video is shortened or stretched to match.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Speed can't be combined with extra clips. Take the extra clips out first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear {
            if let at = vm.speedSegments.first(where: { vm.playhead >= $0.start && vm.playhead < $0.end }) {
                factor = at.factor
            }
        }
    }
}

/// Keys for the editor, caught at the window so they never fire while a text
/// field is being typed in. Installed while the editor page is showing.
final class EditorKeyMonitor {
    private var monitor: Any?

    func install(vm: EditorViewModel) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated { Self.handle(event, vm: vm) }
            return handled ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { remove() }

    @MainActor
    private static func handle(_ event: NSEvent, vm: EditorViewModel) -> Bool {
        guard vm.hasVideo, vm.savedExportURL == nil, !vm.isExporting,
              let window = event.window,
              window.styleMask.contains(.titled), window.attachedSheet == nil,
              window.title == "Greenroom",
              !(window.firstResponder is NSText) else { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers ?? ""
        let command = flags.contains(.command)

        if command {
            // Zoom the timeline.
            guard !flags.contains(.option), !flags.contains(.control) else { return false }
            if key == "=" || key == "+" {
                vm.timelineZoom = min(16, vm.timelineZoom * 2)
                return true
            }
            if key == "-" {
                vm.timelineZoom = max(1, vm.timelineZoom / 2)
                return true
            }
            return false
        }
        guard !flags.contains(.control), !flags.contains(.option) else { return false }
        let shift = flags.contains(.shift)

        switch event.keyCode {
        case 49:   // space
            vm.togglePlay()
            return true
        case 123:  // left
            vm.step(by: shift ? -1 : -5)
            return true
        case 124:  // right
            vm.step(by: shift ? 1 : 5)
            return true
        case 51, 117:  // delete, forward delete
            if vm.selection != nil {
                vm.removeSelection()
            } else if vm.selectedCutID != nil {
                vm.deleteSelectedCut()
            } else if let id = vm.selectedAnnotationID {
                vm.removeAnnotation(id: id)
            } else if let id = vm.selectedSpeedID {
                vm.removeSpeedSegment(id: id)
            } else {
                return false
            }
            return true
        case 53:   // escape
            if vm.hasSomethingToDismiss {
                vm.dismissSelections()
            } else {
                vm.backRequests += 1
            }
            return true
        default:
            break
        }

        guard !shift else { return false }
        switch key {
        case "[":
            vm.setTrimStartToPlayhead()
        case "]":
            vm.setTrimEndToPlayhead()
        case "i":
            vm.setSelectionStart(to: vm.playhead)
        case "o":
            vm.setSelectionEnd(to: vm.playhead)
        case "b":
            vm.beginAnnotationPlacement(.blur)
        default:
            return false
        }
        return true
    }
}

/// Format + quality picker with a live output-size estimate.
struct ExportOptionsSheet: View {
    @EnvironmentObject private var vm: EditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Save Video", systemImage: "square.and.arrow.down")
                .font(.title3.bold())

            HStack {
                Text("Edited length")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(TimeFormatting.clock(vm.editedDuration))
                    .font(.system(.callout, design: .monospaced))
            }
            .font(.callout)

            VStack(alignment: .leading, spacing: 6) {
                Text("SAVE AS")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                TextField("File name", text: $vm.exportName)
                    .textFieldStyle(.greenroom)
                Text("Saved as its own recording in Greenroom, in a new \u{201C}\u{2013} Edited\u{201D} folder next to the original.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("FORMAT")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                Picker("", selection: $vm.exportFormat) {
                    ForEach(ExportFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("QUALITY")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                GreenroomSegmented("Quality", selection: $vm.exportQuality, options: Array(ExportQuality.allCases)) { quality in
                    Text(quality.rawValue)
                }
            }

            HStack {
                Label("Estimated file size", systemImage: "internaldrive")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(vm.estimatedSizeText)
                    .font(.system(.callout, design: .monospaced).weight(.bold))
                    .foregroundStyle(EditorTheme.accent)
            }
            .font(.callout)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))

            Text("The estimate comes from the encoder; the actual size varies slightly with content complexity.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") {
                    vm.showExportOptions = false
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button("Save") {
                    vm.showExportOptions = false
                    vm.exportPanelAndRun()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(20)
        .frame(width: 430)
        .onAppear { vm.updateExportEstimate() }
        .onChange(of: vm.exportFormat) { _, _ in vm.updateExportEstimate() }
        .onChange(of: vm.exportQuality) { _, _ in vm.updateExportEstimate() }
    }
}


/// Drag-anywhere speed picker (0.25×–8× in quarter steps) — plain SwiftUI
/// shapes, immune to the popover first-render glitches of native Slider.
struct SpeedDial: View {
    @Binding var value: Double

    private let low = 0.25
    private let high = 8.0

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let knob: CGFloat = 16
            let fraction = CGFloat((value - low) / (high - low))
            let knobCenter = fraction * (width - knob) + knob / 2
            ZStack(alignment: .topLeading) {
                // The exact value rides right above the knob.
                Text(String(format: "%g×", value))
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(value < 1 ? Color.primary : Brand.text)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .position(x: min(max(knobCenter, 20), width - 20), y: 10)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.16))
                        .frame(height: 5)
                    Capsule()
                        .fill(EditorTheme.accent)
                        .frame(width: max(3, knobCenter), height: 5)
                    Circle()
                        .fill(.white)
                        .frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                        .offset(x: fraction * (width - knob))
                }
                .frame(height: 24)
                .offset(y: 22)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let usable = max(1, width - knob)
                        let raw = min(max(0, (gesture.location.x - knob / 2) / usable), 1)
                        let mapped = low + Double(raw) * (high - low)
                        value = (mapped * 4).rounded() / 4
                    }
            )
        }
        .frame(height: 48)
    }
}
