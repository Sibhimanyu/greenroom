// Ported from Recorditor (ZRecorditor @7210322, native/MacRecorder/Editor/EditAssistant.swift).
import SwiftUI

struct AssistantMessage: Identifiable, Equatable {
    let id = UUID()
    let isUser: Bool
    let text: String
}

/// Prompt-driven editing: parses natural-language commands and applies them
/// to the editor. Rule-based for now — the UI and command surface are built
/// so an LLM backend (2.0 roadmap) can replace `respond` without UI changes.
@MainActor
enum EditAssistant {

    static func respond(to rawInput: String, vm: EditorViewModel) -> String {
        // Multi-step commands: "cut 0:10 to 0:20 then crop left half".
        let steps = rawInput.split(separator: /(?i)\s*(?:\bthen\b|;)\s*/)
        if steps.count > 1 {
            return steps.enumerated().map { index, step in
                "\(index + 1). \(applyOne(String(step), vm: vm))"
            }.joined(separator: "\n")
        }
        return applyOne(rawInput, vm: vm)
    }

    private static func applyOne(_ rawInput: String, vm: EditorViewModel) -> String {
        var input = rawInput.lowercased()

        // "clip N" targets a merge clip; strip it so N isn't parsed as a time.
        var clipIndex: Int?
        if let match = input.firstMatch(of: /(?:merge\s*)?clip\s*(\d+)/) {
            clipIndex = Int(match.1).map { $0 - 1 }
            input = input.replacingCharacters(in: match.range, with: " ")
        }
        let times = parseTimes(in: input)

        // ---- global actions
        if input.contains("undo") {
            guard vm.canUndo else { return "Nothing to undo." }
            vm.undo()
            return "Undone. Edited length is now \(TimeFormatting.clock(vm.editedDuration))."
        }
        if input.contains("redo") {
            guard vm.canRedo else { return "Nothing to redo." }
            vm.redo()
            return "Redone."
        }
        if input.contains("clear") && (input.contains("edit") || input.contains("all") || input.contains("everything")) {
            vm.clearAllEdits()
            return "Cleared everything — cuts, trims, crop and merge clips. ⌘Z brings them back."
        }
        if input.contains("export") {
            vm.exportPanelAndRun()
            return "Opening the export dialog — pick where to save the MP4."
        }
        if input.contains("merge") || input.contains("add video") || input.contains("append") {
            vm.addMergeClipPanel()
            return "Choose the videos to append — you can reorder and trim them afterwards."
        }

        // ---- status & summary
        if input.contains("status") || input.contains("summary")
            || (input.contains("what") && (input.contains("edit") || input.contains("change") || input.contains("done")))
            || input.contains("how long") || (input.contains("duration") && times.isEmpty) {
            return summary(vm)
        }

        // ---- "everything before/after X" trims
        if (input.contains("before") || input.contains("after")),
           input.contains("remove") || input.contains("cut") || input.contains("delete") || input.contains("everything"),
           let t = times.first {
            vm.pushUndo()
            if input.contains("after") {
                vm.trimEnd = max(min(vm.duration, t), vm.trimStart + 0.1)
                return "Removed everything after \(TimeFormatting.clock(t)) — video ends there now."
            } else {
                vm.trimStart = min(max(0, t), vm.trimEnd - 0.1)
                return "Removed everything before \(TimeFormatting.clock(t)) — video starts there now."
            }
        }

        // ---- "keep only the first/last N"
        if input.contains("keep"), input.contains("only") || input.contains("just"), let t = times.first {
            vm.pushUndo()
            if input.contains("last") {
                vm.trimStart = max(0, vm.duration - t)
                vm.trimEnd = vm.duration
                return "Keeping only the last \(TimeFormatting.spoken(t))."
            }
            vm.trimStart = 0
            vm.trimEnd = min(vm.duration, max(t, 0.1))
            return "Keeping only the first \(TimeFormatting.spoken(t))."
        }

        // ---- cuts
        if input.contains("delete") && input.contains("cut") {
            if input.contains("all") {
                guard !vm.cuts.isEmpty else { return "There are no cuts." }
                vm.pushUndo()
                vm.cuts = []
                return "Removed all cuts."
            }
            if let number = Int(input.firstMatch(of: /cut\s*(\d+)/)?.1 ?? ""), vm.cuts.indices.contains(number - 1) {
                vm.deleteCut(id: vm.cuts[number - 1].id)
                return "Deleted cut \(number)."
            }
            guard vm.selectedCutID != nil else { return "Select a cut on the timeline first, or say “delete cut 2”." }
            vm.deleteSelectedCut()
            return "Deleted the selected cut."
        }
        if (input.contains("cut") || input.contains("remove") || input.contains("delete")) && clipIndex == nil {
            if input.contains("first"), let t = times.first {
                vm.addCut(start: 0, end: t)
                return "Removed the first \(TimeFormatting.spoken(t)). Edited length: \(TimeFormatting.clock(vm.editedDuration))."
            }
            if input.contains("last"), let t = times.first {
                vm.addCut(start: vm.duration - t, end: vm.duration)
                return "Removed the last \(TimeFormatting.spoken(t)). Edited length: \(TimeFormatting.clock(vm.editedDuration))."
            }
            if times.count >= 2 {
                let a = min(times[0], times[1]), b = max(times[0], times[1])
                vm.addCut(start: a, end: b)
                return "Cut \(TimeFormatting.clock(a)) → \(TimeFormatting.clock(b)) (\(TimeFormatting.spoken(b - a)) removed). Edited length: \(TimeFormatting.clock(vm.editedDuration))."
            }
        }

        // ---- trims
        if input.contains("trim") || input.contains("keep") || input.contains("start at") || input.contains("end at") {
            if let clipIndex {
                guard vm.mergeClips.indices.contains(clipIndex) else {
                    return "There's no merge clip \(clipIndex + 1) — the list has \(vm.mergeClips.count)."
                }
                guard times.count >= 2 else { return "Tell me both times, e.g. “trim clip \(clipIndex + 1) from 0:05 to 0:20”." }
                vm.pushUndo()
                vm.setMergeTrimStart(index: clipIndex, to: min(times[0], times[1]))
                vm.setMergeTrimEnd(index: clipIndex, to: max(times[0], times[1]))
                let clip = vm.mergeClips[clipIndex]
                return "Clip \(clipIndex + 1) now plays \(TimeFormatting.clock(clip.trimStart)) → \(TimeFormatting.clock(clip.trimEnd)) (\(TimeFormatting.spoken(clip.trimmedDuration)))."
            }
            if input.contains("first") || input.contains("start at"), let t = times.first, times.count == 1 {
                vm.pushUndo()
                vm.trimStart = min(max(0, t), vm.trimEnd - 0.1)
                return "Main video now starts at \(TimeFormatting.clock(vm.trimStart))."
            }
            if input.contains("last"), let t = times.first, times.count == 1 {
                vm.pushUndo()
                vm.trimEnd = max(vm.duration - t, vm.trimStart + 0.1)
                return "Trimmed the last \(TimeFormatting.spoken(t)) — main video ends at \(TimeFormatting.clock(vm.trimEnd))."
            }
            if input.contains("end at"), let t = times.first, times.count == 1 {
                vm.pushUndo()
                vm.trimEnd = max(min(vm.duration, t), vm.trimStart + 0.1)
                return "Main video now ends at \(TimeFormatting.clock(vm.trimEnd))."
            }
            if times.count >= 2 {
                vm.pushUndo()
                vm.trimStart = min(max(0, min(times[0], times[1])), vm.duration - 0.2)
                vm.trimEnd = max(min(vm.duration, max(times[0], times[1])), vm.trimStart + 0.1)
                return "Keeping \(TimeFormatting.clock(vm.trimStart)) → \(TimeFormatting.clock(vm.trimEnd)) of the main video."
            }
        }

        // ---- crop
        if input.contains("crop") {
            if input.contains("clear") || input.contains("remove") || input.contains("reset") {
                vm.setCrop(nil)
                return "Crop cleared."
            }
            if let match = input.firstMatch(of: /(\d{2,3})\s*(?:%|percent)/), let pct = Double(match.1),
               (20...100).contains(pct) {
                let f = pct / 100
                vm.setCrop(CGRect(x: (1 - f) / 2, y: (1 - f) / 2, width: f, height: f))
                return "Cropped to the centered \(Int(pct))% of the frame — applied on export."
            }
            let presets: [(String, CGRect, String)] = [
                ("top left", CGRect(x: 0, y: 0, width: 0.5, height: 0.5), "top-left quarter"),
                ("top right", CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5), "top-right quarter"),
                ("bottom left", CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5), "bottom-left quarter"),
                ("bottom right", CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5), "bottom-right quarter"),
                ("left", CGRect(x: 0, y: 0, width: 0.5, height: 1), "left half"),
                ("right", CGRect(x: 0.5, y: 0, width: 0.5, height: 1), "right half"),
                ("top", CGRect(x: 0, y: 0, width: 1, height: 0.5), "top half"),
                ("bottom", CGRect(x: 0, y: 0.5, width: 1, height: 0.5), "bottom half"),
                ("center", CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6), "center region"),
                ("middle", CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6), "center region"),
            ]
            for (keyword, rect, name) in presets where input.contains(keyword) {
                vm.setCrop(rect)
                return "Cropped to the \(name) — applied on export."
            }
            return "Tell me where: “crop left half”, “crop top half”, “crop center”, or “clear crop”. For a precise area use the Crop button and drag."
        }

        if input.contains("zoom in") {
            vm.setCrop(CGRect(x: 0.15, y: 0.15, width: 0.7, height: 0.7))
            return "Zoomed in — cropped to the centered 70% of the frame."
        }
        if input.contains("zoom out") {
            vm.setCrop(nil)
            return "Zoomed back out — crop cleared."
        }

        // ---- playback
        if input.contains("go to") || input.contains("seek") || input.contains("jump") {
            if input.contains("start") || input.contains("beginning") {
                vm.seek(to: 0)
                return "Jumped to the beginning."
            }
            if input.contains("end"), times.isEmpty {
                vm.seek(to: max(0, vm.duration - 0.1))
                return "Jumped to the end."
            }
            guard let t = times.first else { return "Give me a time, e.g. “go to 1:20”. " }
            vm.seek(to: t)
            return "Jumped to \(TimeFormatting.clock(t))."
        }
        if input.contains("pause") || input.contains("stop") {
            if vm.isPlaying { vm.togglePlay() }
            return "Paused."
        }
        if input.contains("play") {
            if !vm.isPlaying { vm.togglePlay() }
            return "Playing."
        }

        // Nothing matched — nudge toward the closest topic instead of a
        // generic wall of help.
        if !times.isEmpty {
            return "I found the time \(TimeFormatting.clock(times[0])) but not what to do with it. Try cutting, trimming, or \(String("go to \(TimeFormatting.clock(times[0]))"))."
        }
        if input.contains("audio") || input.contains("music") || input.contains("song") || input.contains("voiceover") {
            if input.contains("add") || input.contains("mix") || input.contains("background") {
                vm.addAudioPanel()
                return "Choose the audio file — it gets mixed over the video on export (volume slider is in the toolbar)."
            }
            if input.contains("remove") || input.contains("delete"), vm.overlayAudioURL != nil {
                vm.overlayAudioURL = nil
                return "Background audio removed."
            }
        }
        if input.contains("mute") || input.contains("volume") {
            return "Track volume editing isn't here yet — but \u{201c}add audio\u{201d} mixes a music/voiceover file over the video."
        }
        if input.contains("text") || input.contains("caption") || input.contains("subtitle") || input.contains("speed") || input.contains("slow") {
            return "Not supported yet — today I can cut, trim, crop, merge, seek and export. Captions and speed changes are on the roadmap."
        }
        return """
        I can do things like:
        • cut from 1:20 to 1:45  ·  remove the first 10s
        • remove everything after 2:00  ·  keep only the first 30s
        • trim clip 2 from 0:05 to 0:20  ·  crop 80%  ·  zoom in
        • cut 0:10 to 0:20 then crop bottom right
        • what's the status  ·  delete cut 1  ·  undo  ·  export
        """
    }

    /// One-glance report of everything applied so far.
    private static func summary(_ vm: EditorViewModel) -> String {
        var lines = ["Original: \(TimeFormatting.clock(vm.duration))  ·  Edited: \(TimeFormatting.clock(vm.editedDuration))"]
        if vm.trimStart > 0 || vm.trimEnd < vm.duration {
            lines.append("Trim: \(TimeFormatting.clock(vm.trimStart)) → \(TimeFormatting.clock(vm.trimEnd))")
        }
        if !vm.cuts.isEmpty {
            let list = vm.cuts.enumerated()
                .map { "\($0.offset + 1)) \(TimeFormatting.clock($0.element.start))–\(TimeFormatting.clock($0.element.end))" }
                .joined(separator: "  ")
            lines.append("Cuts: \(list)")
        }
        if vm.cropRect != nil { lines.append("Crop: set (applied on export)") }
        if !vm.mergeClips.isEmpty { lines.append("Merge clips: \(vm.mergeClips.count) appended") }
        if lines.count == 1 { lines.append("No edits yet — the video is untouched.") }
        return lines.joined(separator: "\n")
    }

    /// Parses times: "1:23", "01:02:03", "90s", "2m", and bare numbers
    /// (seconds) when nothing else matches.
    private static func parseTimes(in text: String) -> [Double] {
        var results: [Double] = []
        var consumed = text
        for match in text.matches(of: /(\d+):(\d{1,2})(?::(\d{1,2}))?/) {
            let a = Double(match.1) ?? 0
            let b = Double(match.2) ?? 0
            if let cRaw = match.3, let c = Double(cRaw) {
                results.append(a * 3600 + b * 60 + c)
            } else {
                results.append(a * 60 + b)
            }
            consumed = consumed.replacingOccurrences(of: String(match.0), with: " ")
        }
        for match in consumed.matches(of: /(\d+(?:\.\d+)?)\s*(m(?:in(?:ute)?s?)?|s(?:ec(?:ond)?s?)?)\b/) {
            let value = Double(match.1) ?? 0
            results.append(String(match.2).hasPrefix("m") ? value * 60 : value)
            consumed = consumed.replacingOccurrences(of: String(match.0), with: " ")
        }
        if results.isEmpty {
            for match in consumed.matches(of: /\d+(?:\.\d+)?/) {
                results.append(Double(match.0) ?? 0)
            }
        }
        return results
    }
}

// MARK: - Chat UI

struct AssistantPanel: View {
    @EnvironmentObject private var vm: EditorViewModel
    @State private var input = ""
    @FocusState private var focused: Bool

    private let examples = [
        "Cut from 0:10 to 0:20",
        "Remove everything after 2:00",
        "Cut 0:05 to 0:10 then crop left half",
        "Zoom in",
        "What's the status?",
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(EditorTheme.accent)
                Text("AI Assistant")
                    .font(.callout.weight(.semibold))
                Spacer()
                if !vm.assistantMessages.isEmpty {
                    Button {
                        vm.assistantMessages.removeAll()
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear the conversation")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.04))
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if vm.assistantMessages.isEmpty {
                            intro
                        }
                        ForEach(vm.assistantMessages) { message in
                            bubble(message).id(message.id)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: vm.assistantMessages.count) { _, _ in
                    if let last = vm.assistantMessages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()
            HStack(spacing: 8) {
                TextField("e.g. cut from 1:20 to 1:45", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(EditorTheme.accent)
                }
                .buttonStyle(.plain)
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Apply the edit")
            }
            .padding(10)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Edit by prompt", systemImage: "sparkles")
                .font(.callout.weight(.semibold))
                .foregroundStyle(EditorTheme.accent)
            Text("Type what you want changed and I'll apply it to the timeline. Try:")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(examples, id: \.self) { example in
                Button {
                    input = example
                    send()
                } label: {
                    Text(example)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func bubble(_ message: AssistantMessage) -> some View {
        HStack {
            if message.isUser { Spacer(minLength: 30) }
            Text(message.text)
                .font(.callout)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 11)
                        .fill(message.isUser ? AnyShapeStyle(EditorTheme.accentGradient) : AnyShapeStyle(Color.white.opacity(0.07))))
                .foregroundStyle(message.isUser ? .white : .primary)
            if !message.isUser { Spacer(minLength: 30) }
        }
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        vm.assistantMessages.append(AssistantMessage(isUser: true, text: text))
        let reply = EditAssistant.respond(to: text, vm: vm)
        vm.assistantMessages.append(AssistantMessage(isUser: false, text: reply))
        focused = true
    }
}
