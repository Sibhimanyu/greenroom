// Ported from Recorditor (ZRecorditor @7210322, native/MacRecorder/Editor/EditorView.swift).
import SwiftUI

struct EditorView: View {
    @EnvironmentObject private var vm: EditorViewModel
    @State private var showCloseConfirm = false
    @State private var showMergeSourceToolbar = false
    @State private var showEffectsPopover = false
    @State private var newSpeedFactor: Double = 1
    @State private var speedFrom = "0:00"
    @State private var speedTo = "0:10"
    @State private var savedPlaybackURL: URL?

    /// The single segment covering the whole video, when that's the state.
    private var wholeVideoSpeedSegment: EditorViewModel.SpeedSegment? {
        guard vm.speedSegments.count == 1, let segment = vm.speedSegments.first,
              segment.start <= vm.trimStart + 0.2, segment.end >= vm.trimEnd - 0.2 else { return nil }
        return segment
    }
    @State private var showMergeSourcePanel = false
    @State private var showAudioOptions = false
    @State private var sideTab = 0
    @State private var showInspector = true
    @StateObject private var library = EditorRecordingLibrary()

    var body: some View {
        ZStack {
            if !vm.hasVideo {
                emptyState
            } else {
                editor
            }
            if let saved = vm.savedExportURL {
                savedPopup(saved)
            }
        }
        .sheet(isPresented: Binding(get: { savedPlaybackURL != nil },
                                    set: { if !$0 { savedPlaybackURL = nil } })) {
            if let url = savedPlaybackURL {
                EditorPlaybackSheet(url: url, title: url.lastPathComponent)
            }
        }
    }

    /// Post-save popup over the editor's start page: the session is closed,
    /// the file is in Recordings, one click re-opens it for further edits.
    private func savedPopup(_ url: URL) -> some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
                .onTapGesture { vm.savedExportURL = nil }
            VStack(spacing: 16) {
                ZStack {
                    Circle().fill(Color.green.opacity(0.15)).frame(width: 72, height: 72)
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.green)
                }
                Text("Saved \(url.lastPathComponent)")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("It's in your Recordings, ready to share.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        savedPlaybackURL = url
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    Button {
                        vm.savedExportURL = nil
                        Task { await vm.load(url: url) }
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
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(30)
            .frame(maxWidth: 460)
            .greenroomGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .transition(.opacity)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(EditorTheme.accent.opacity(0.12))
                    .frame(width: 92, height: 92)
                Image(systemName: "film.stack")
                    .font(.system(size: 40))
                    .foregroundStyle(EditorTheme.accent)
            }
            Text("Load a video to start editing")
                .font(.title3.weight(.semibold))
            Text("Trim, cut, crop and merge — then export a single MP4.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Load Video…") {
                vm.openVideoPanel()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            if let message = vm.errorMessage {
                Text(message).foregroundStyle(EditorTheme.danger)
            }

            // Recent recordings from the Library — one click to start editing.
            if !library.items.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Or pick a recording")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], spacing: 14) {
                            ForEach(library.items) { item in
                                libraryPick(item)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .frame(maxHeight: 480)
                }
                .frame(maxWidth: 900)
                .padding(.top, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            library.refresh()
        }
    }

    private func libraryPick(_ item: EditorRecordingLibrary.Item) -> some View {
        Button {
            Task { await vm.load(url: item.url) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                EditorRecordingThumb(url: item.url)
                .frame(width: 190, height: 107)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(alignment: .bottomTrailing) {
                    EditorRecordingDuration(url: item.url)
                        .font(.caption2.monospaced().weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.black.opacity(0.65)))
                        .padding(5)
                }
                Text(item.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 190, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .help("Edit this recording")
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // ---- player + transport (shrinks first; side panel is fixed)
                VStack(spacing: 8) {
                    GeometryReader { geo in
                        ZStack {
                            PlayerContainerView(player: vm.player)
                            if vm.isCropping {
                                CropOverlayView(containerSize: geo.size)
                            }
                            AnnotationPreviewOverlay(containerSize: geo.size)
                            if abs(vm.activePreviewRate - 1) > 0.01 {
                                VStack {
                                    HStack {
                                        Spacer()
                                        Label(String(format: "%g×", vm.activePreviewRate),
                                              systemImage: vm.activePreviewRate < 1 ? "tortoise.fill" : "hare.fill")
                                            .font(.callout.bold())
                                            .foregroundStyle(vm.activePreviewRate < 1 ? .cyan : .orange)
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
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(EditorTheme.cardStroke, lineWidth: 1))
                        // Status toast floats over the player — messages at
                        // the bottom of the scrolling side panel went unseen.
                        .overlay(alignment: .top) {
                            messageToast
                        }
                        // Saving takes a while (two encode passes with
                        // effects) — make the progress impossible to miss.
                        .overlay {
                            if vm.isExporting {
                                ZStack {
                                    Color.black.opacity(0.55)
                                    VStack(spacing: 14) {
                                        ProgressView(value: vm.exportProgress)
                                            .progressViewStyle(.circular)
                                            .controlSize(.large)
                                        Text("Saving… \(Int(vm.exportProgress * 100))%")
                                            .font(.title3.weight(.semibold))
                                        Text("Effects and edits are being rendered into the video.")
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
                    transport
                }
                .padding(12)
            }

            Divider()
            if let exportURL = vm.lastExportURL {
                exportBanner(exportURL)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
            }
            toolsRow
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            EditorTimelineView()
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
        }
        .inspector(isPresented: $showInspector) {
            VStack(spacing: 0) {
                GreenroomSegmented("Side panel", selection: $sideTab, options: [0, 1]) { tab in
                    if tab == 0 {
                        Label("Info", systemImage: "info.circle")
                    } else {
                        Label("Assistant", systemImage: "sparkles")
                    }
                }
                .padding(10)
                .help("Info shows file details and edits; Assistant edits the video from text prompts")
                if sideTab == 0 {
                    sidePanel
                } else {
                    AssistantPanel()
                }
            }
            .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
        }
        .toolbar { editorToolbar }
        .sheet(isPresented: $vm.showExportOptions) {
            ExportOptionsSheet()
                .environmentObject(vm)
        }
        .confirmationDialog(
            "Cancel this edit?",
            isPresented: $showCloseConfirm
        ) {
            Button("Discard Edits", role: .destructive) {
                vm.closeVideo()
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Cuts, trims, crop and merge clips will be lost unless you save first.")
        }
    }

    // MARK: window toolbar

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                vm.undo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!vm.canUndo)
            .keyboardShortcut("z", modifiers: [.command])
            .help("Undo the last edit (⌘Z)")

            Button {
                vm.redo()
            } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .disabled(!vm.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .help("Redo (⇧⌘Z)")
        }

        ToolbarItem(placement: .principal) {
            GreenroomSegmented("Mode", selection: $vm.mode, options: TimelineMode.allCases) { mode in
                Text(mode.rawValue)
            }
            .help("Trim: drag the edge handles · Cut: drag on the timeline to mark removals")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                showEffectsPopover.toggle()
            } label: {
                Label("Effects", systemImage: "sparkles")
            }
            .popover(isPresented: $showEffectsPopover, arrowEdge: .bottom) {
                effectsPopover
                    .onAppear {
                        speedFrom = TimeFormatting.clock(vm.playhead)
                        speedTo = TimeFormatting.clock(min(vm.playhead + 10, vm.trimEnd))
                        // Reopenings reflect the applied state: the dial sits
                        // at the active speed.
                        if let whole = wholeVideoSpeedSegment {
                            newSpeedFactor = whole.factor
                        } else if let at = vm.speedSegments.first(where: {
                            vm.playhead >= $0.start && vm.playhead < $0.end
                        }) {
                            newSpeedFactor = at.factor
                        }
                    }
            }
            .help("Click ripples, keystrokes, captions, blur, arrows, speed — applied on Save")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                showInspector.toggle()
            } label: {
                Label("Side Panel", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the Info / Assistant panel")
        }

        ToolbarItem(placement: .cancellationAction) {
            Button {
                if vm.hasUnsavedEdits {
                    showCloseConfirm = true
                } else {
                    vm.closeVideo()
                }
            } label: {
                Text("Cancel")
            }
            .disabled(vm.isExporting)
            .help("Discard all edits and close this video")
        }

        ToolbarItem(placement: .confirmationAction) {
            Button {
                vm.showExportOptions = true
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .greenroomGlassButton(prominent: true)
            .tint(Brand.green)
            .disabled(vm.isExporting)
            .help("Choose format and quality, see the estimated size, then save")
        }
    }

    // MARK: transport

    private var transport: some View {
        HStack(spacing: 14) {
            Button {
                vm.step(by: -10)
            } label: {
                Image(systemName: "gobackward.10")
            }
            .editorRoundControl()
            .keyboardShortcut(.leftArrow, modifiers: [])
            .help("Back 10 seconds (←)")

            Button {
                vm.togglePlay()
            } label: {
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 28)
            }
            .editorRoundControl()
            .keyboardShortcut(.space, modifiers: [])
            .help("Play / pause (Space)")

            Button {
                vm.step(by: 10)
            } label: {
                Image(systemName: "goforward.10")
            }
            .editorRoundControl()
            .keyboardShortcut(.rightArrow, modifiers: [])
            .help("Forward 10 seconds (→)")

            Text("\(TimeFormatting.clockWithTenths(vm.playhead)) / \(TimeFormatting.clock(vm.timelineDuration))")
                .font(.system(.body, design: .monospaced))
            if let index = vm.playingMergeIndex {
                Text("Merge clip \(index + 1)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.purple.opacity(0.15)))
            }

            Toggle("Preview edits", isOn: $vm.previewEdits)
                .toggleStyle(.checkbox)
                .help("Skip cut regions and respect trim while playing")

            Spacer()

            if vm.isExporting {
                ProgressView(value: vm.exportProgress)
                    .frame(width: 140)
                Text("\(Int(vm.exportProgress * 100))%")
                    .font(.caption.monospaced())
                Button("Cancel") {
                    vm.cancelExport()
                }
                .controlSize(.small)
                .help("Stop the export — no file is saved")
            }
        }
    }

    /// Shown after a successful export: keep going, wipe the edits, or start
    /// a fresh session on the exported file.
    private func exportBanner(_ url: URL) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title3)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Saved \(url.lastPathComponent)")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("It's in your Recordings. Keep editing, clear the edits, or edit the exported file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Edit Exported Video") {
                vm.editExportedVideo()
            }
            .buttonStyle(.borderedProminent)
            Button("Clear Edits") {
                vm.clearAllEdits()
            }
            .help("Remove all cuts, trims, crop and merge clips — undoable with ⌘Z")
            Button {
                vm.lastExportURL = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.bold())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Keep editing")
        }
        .editorCard(padding: 12, cornerRadius: 10)
    }

    // MARK: tools above the timeline (the window toolbar holds undo, mode, effects, cancel, save)

    @ViewBuilder
    private func toolsContent(spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            Button {
                vm.deleteSelectedCut()
            } label: {
                Label("Delete Cut", systemImage: "trash")
            }
            .disabled(vm.selectedCutID == nil)
            .keyboardShortcut(.delete, modifiers: [])
            .help("Remove the selected cut region")

            Divider().frame(height: 18).padding(.horizontal, spacing >= 8 ? 2 : -2)

            Button {
                vm.isCropping.toggle()
            } label: {
                Label(vm.isCropping ? "Done Cropping" : "Crop", systemImage: "crop")
            }
            .tint(vm.isCropping ? .yellow : nil)
            .help("Drag a rectangle over the video to crop it on export")

            if vm.cropRect != nil {
                Button("Clear Crop") {
                    vm.setCrop(nil)
                }
            }


            Button {
                showMergeSourceToolbar.toggle()
            } label: {
                Label("Merge Videos…", systemImage: "plus.rectangle.on.rectangle")
            }
            .fixedSize()
            .popover(isPresented: $showMergeSourceToolbar, arrowEdge: .bottom) {
                mergeSourcePopover(isPresented: $showMergeSourceToolbar)
            }
            .help("Append one or more videos after this one — browse Files, or pick from your recordings")

            if let audioURL = vm.overlayAudioURL {
                HStack(spacing: 6) {
                    Image(systemName: "music.note")
                        .foregroundStyle(EditorTheme.accent)
                    Button {
                        showAudioOptions.toggle()
                    } label: {
                        Text(audioURL.deletingPathExtension().lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 80)
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .help("Audio options: which part to use, repeat, volume")
                    .popover(isPresented: $showAudioOptions, arrowEdge: .bottom) {
                        audioOptionsPopover(name: audioURL.deletingPathExtension().lastPathComponent)
                    }
                    Menu {
                        Button("Start at playhead (\(TimeFormatting.clock(vm.editedTimeAtPlayhead())))") {
                            vm.overlayAudioStart = vm.editedTimeAtPlayhead()
                        }
                        Button("Start at 0:00") {
                            vm.overlayAudioStart = 0
                        }
                    } label: {
                        Text("at \(TimeFormatting.clock(vm.overlayAudioStart))")
                            .font(.caption.monospaced())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("Where the audio begins in the exported video — move the playhead, then pick 'Start at playhead'")
                    Slider(value: $vm.overlayAudioVolume, in: 0...1)
                        .frame(width: 56)
                        .help("Background audio volume")
                    Button {
                        vm.overlayAudioURL = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove the background audio")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.07)))
                .help("Mixed over the video on export")
            } else {
                Button {
                    vm.addAudioPanel()
                } label: {
                    Label("Add Audio…", systemImage: "music.note")
                }
                .help("Mix a music or voiceover file over the video — applied on export")
            }

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

    @ViewBuilder
    private var messageToast: some View {
        if let message = vm.errorMessage ?? vm.exportMessage {
            let isError = vm.errorMessage != nil
            HStack(spacing: 8) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isError ? .red : .green)
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
                .stroke((isError ? Color.red : Color.green).opacity(0.5), lineWidth: 1))
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

    /// All the applied-on-Save enhancements in one place.
    private var effectsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ANNOTATE (drag on the video after choosing)")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button { startPlacement(.blur) } label: { Label("Blur", systemImage: "eye.slash") }
                    .help("Hide sensitive content behind a blur box")
                Button { startPlacement(.text) } label: { Label("Text", systemImage: "textformat") }
                Button { startPlacement(.arrow) } label: { Label("Arrow", systemImage: "arrow.up.right") }
            }
            Divider()

            Text("SPEED")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            // Custom control: AppKit-backed Slider rendered broken on the
            // popover's first layout pass, whatever its configuration.
            SpeedDial(value: $newSpeedFactor)
            HStack {
                Text("0.25×")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("8×")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text("From")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("0:00", text: $speedFrom)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 62)
                Text("To")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("0:10", text: $speedTo)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 62)
                Spacer()
                Text("prefilled from the playhead")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                Button {
                    if let from = EditorViewModel.parseClock(speedFrom),
                       let to = EditorViewModel.parseClock(speedTo) {
                        vm.applySpeed(factor: newSpeedFactor, from: from, to: to)
                        showEffectsPopover = false
                    }
                } label: {
                    Label(String(format: "Apply %g× to range", newSpeedFactor),
                          systemImage: newSpeedFactor < 1 ? "tortoise.fill" : "hare.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!vm.mergeClips.isEmpty || abs(newSpeedFactor - 1) < 0.01)
                Button {
                    vm.applySpeedToWholeVideo(factor: newSpeedFactor)
                    showEffectsPopover = false
                } label: {
                    if wholeVideoSpeedSegment != nil {
                        Label(String(format: "Whole video %g×", wholeVideoSpeedSegment?.factor ?? 1),
                              systemImage: "checkmark")
                    } else {
                        Text("Whole video")
                    }
                }
                .tint(wholeVideoSpeedSegment != nil ? .orange : nil)
                .buttonStyle(.bordered)
                .disabled(!vm.mergeClips.isEmpty || abs(newSpeedFactor - 1) < 0.01)
            }
            if !vm.speedSegments.isEmpty {
                Text(vm.speedSegments.map {
                    String(format: "%g× %@–%@", $0.factor,
                           TimeFormatting.clock($0.start), TimeFormatting.clock($0.end))
                }.joined(separator: "  ·  "))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !vm.mergeClips.isEmpty {
                Text("Speed segments aren't available while merge clips are added.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Below 1× is slow motion. Segments can be adjusted or removed in the side panel.")
                    .fixedSize(horizontal: false, vertical: true)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text("Everything here is rendered into the video when you Save.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 340)
    }

    private func startPlacement(_ kind: EditedEffects.Annotation.Kind) {
        showEffectsPopover = false
        vm.beginAnnotationPlacement(kind)
    }

    private var toolsRow: some View {
        // Adapts to the real available width: full labels when roomy,
        // tighter when narrow. Labels always stay text.
        HStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                toolsContent(spacing: 12)
                toolsContent(spacing: 8)
                toolsContent(spacing: 5).controlSize(.small)
            }
            Spacer(minLength: 8)
        }
        .frame(height: 46)   // horizontal ScrollViews are vertically greedy
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

            Text("Starts in the video at \(TimeFormatting.clock(vm.overlayAudioStart)) — use the \u{201c}at\u{201d} menu in the toolbar or drag the green bar on the timeline.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: side panel


    private var sidePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                panelSection("FILE INFO") {
                    infoRow("Name", vm.sourceURL?.lastPathComponent ?? "—")
                    infoRow("Duration", TimeFormatting.clock(vm.duration))
                    infoRow("Size", vm.fileSizeText)
                    infoRow("Dimensions", "\(Int(vm.videoSize.width)) × \(Int(vm.videoSize.height))")
                    infoRow("Edited length", TimeFormatting.clock(vm.editedDuration))
                    Button("Load another video…") {
                        vm.openVideoPanel()
                    }
                    .font(.caption)
                    .help("Open a different video file in the editor")
                }

                panelSection("CUTS (\(vm.cuts.count))") {
                    if vm.cuts.isEmpty {
                        Text("Switch to Cut mode and drag on the timeline.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(vm.cuts) { cut in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(TimeFormatting.clock(cut.start)) → \(TimeFormatting.clock(cut.end))")
                                    .font(.system(.callout, design: .monospaced))
                                Text("\(TimeFormatting.spoken(cut.duration)) removed")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                vm.deleteCut(id: cut.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(vm.selectedCutID == cut.id ? Color.red.opacity(0.18) : Color.secondary.opacity(0.08)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(vm.selectedCutID == cut.id ? Color.red.opacity(0.6) : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            vm.selectedCutID = cut.id
                            vm.seek(to: cut.start)
                        }
                    }
                }

                panelSection("MERGE (\(vm.mergeClips.count))") {
                    Text("Videos appended after this one on export, in this order.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(vm.mergeClips.enumerated()), id: \.element.id) { index, clip in
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(.caption.bold().monospaced())
                                .foregroundStyle(EditorTheme.accent)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(EditorTheme.accent.opacity(0.15)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(clip.url.lastPathComponent)
                                    .font(.callout)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(clip.isTrimmed
                                     ? "\(TimeFormatting.clock(clip.trimmedDuration)) of \(TimeFormatting.clock(clip.duration)) (trimmed)"
                                     : TimeFormatting.clock(clip.duration))
                                    .font(.caption)
                                    .foregroundStyle(clip.isTrimmed ? Color.purple : .secondary)
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
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                    }
                    Button {
                        showMergeSourcePanel.toggle()
                    } label: {
                        Label("Add videos…", systemImage: "plus")
                            .font(.caption)
                    }
                    .popover(isPresented: $showMergeSourcePanel, arrowEdge: .bottom) {
                        mergeSourcePopover(isPresented: $showMergeSourcePanel)
                    }
                    .help("Append more videos to the export — browse Files, or pick from your recordings")
                }

                if !vm.annotations.isEmpty {
                    panelSection("ANNOTATIONS (\(vm.annotations.count))") {
                        ForEach($vm.annotations) { $annotation in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Image(systemName: annotation.kind == .blur ? "eye.slash"
                                          : annotation.kind == .text ? "textformat" : "arrow.up.right")
                                        .foregroundStyle(EditorTheme.accent)
                                    Text("\(TimeFormatting.clock(annotation.start)) – \(TimeFormatting.clock(annotation.end))")
                                        .font(.caption.monospaced())
                                    Spacer()
                                    Button {
                                        vm.removeAnnotation(id: annotation.id)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                }
                                if annotation.kind == .text {
                                    TextField("Text", text: $annotation.text)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.caption)
                                }
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                        }
                        Text("Shown from the playhead where you placed them; rendered on Save.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if !vm.speedSegments.isEmpty {
                    panelSection("SPEED (\(vm.speedSegments.count))") {
                        ForEach(vm.speedSegments) { segment in
                            HStack(spacing: 6) {
                                Text(String(format: "%g×", segment.factor))
                                    .font(.caption.bold())
                                    .foregroundStyle(.orange)
                                Text("\(TimeFormatting.clock(segment.start)) – \(TimeFormatting.clock(segment.end))")
                                    .font(.caption.monospaced())
                                Spacer()
                                Button {
                                    vm.removeSpeedSegment(id: segment.id)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                        }
                        Text("Preview plays these faster; the saved video is shortened to match.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                panelSection("CROP") {
                    if let crop = vm.cropRect {
                        Text("\(Int(crop.width * vm.videoSize.width)) × \(Int(crop.height * vm.videoSize.height)) px")
                            .font(.system(.callout, design: .monospaced))
                        Text("Previewing the crop — saved on export.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No crop. Use the Crop button under the player.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let message = vm.exportMessage {
                    Label(message, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
                if let message = vm.errorMessage {
                    Text(message)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .padding(14)
        }
    }

    private func panelSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            EditorPanelHeader(title: title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .editorCard(padding: 12, cornerRadius: 10)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.callout)
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
                    .textFieldStyle(.roundedBorder)
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
                    .foregroundStyle(value < 1 ? Color.cyan : Color.orange)
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
