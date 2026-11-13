// Ported from Recorditor (ZRecorditor @7210322, native/MacRecorder/Editor/TimelineView.swift).
import SwiftUI

struct EditorTimelineView: View {
    @EnvironmentObject private var vm: EditorViewModel

    @State private var drag: DragKind?
    @State private var pendingCut: (start: Double, end: Double)?

    private enum DragKind {
        case seeking
        case cutting(anchor: Double)
        case trimLead
        case trimTrail
        case mergeTrimLead(Int)
        case mergeTrimTrail(Int)
    }

    private let rulerHeight: CGFloat = 20
    private let trackHeight: CGFloat = 54
    private let handleWidth: CGFloat = 10
    /// Handles are inset into their clip so boundary neighbors don't overlap.
    private let handleInset: CGFloat = 5

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .topLeading) {
                    ruler(width: width)

                    Group {
                        track(width: width)
                        mergeSegments(width: width)
                        cutRegions(width: width)
                        pendingCutOverlay(width: width)
                        trimShades(width: width)
                        trimHandle(at: vm.trimStart, width: width, isLead: true)
                        trimHandle(at: vm.trimEnd, width: width, isLead: false)
                    }
                    .offset(y: rulerHeight + 4)

                    if vm.overlayAudioURL != nil, vm.overlayClipLength > 0 {
                        audioStrip(width: width)
                    }
                    playheadMarker(width: width)
                }
                .contentShape(Rectangle())
                .gesture(timelineGesture(width: width))
            }
            .frame(height: rulerHeight + trackHeight + 14)

            Text(vm.mode == .cut
                 ? "Cut mode — click & drag on the timeline to mark a region to remove"
                 : "Trim mode — drag the edge handles (main video and each merge clip); click to seek")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 4)
    }

    // MARK: pieces

    private func ruler(width: CGFloat) -> some View {
        let step = niceStep(for: vm.timelineDuration)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(stride(from: 0.0, through: vm.timelineDuration, by: step)), id: \.self) { t in
                let xPos = x(for: t, width: width)
                VStack(spacing: 1) {
                    Text(TimeFormatting.clock(t))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 1, height: 5)
                }
                .position(x: xPos, y: rulerHeight / 2)
            }
        }
        .frame(height: rulerHeight)
    }

    private func track(width: CGFloat) -> some View {
        // Main video occupies [0, duration] of the virtual timeline.
        let mainWidth = max(2, x(for: vm.duration, width: width))
        return RoundedRectangle(cornerRadius: 6)
            .fill(LinearGradient(colors: [Color.blue.opacity(0.75), Color.blue.opacity(0.55)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: mainWidth, height: trackHeight)
            .position(x: mainWidth / 2, y: trackHeight / 2)
    }

    /// Merge clips rendered as numbered segments after the main video, each
    /// with its own trim handles + shading for trimmed-away parts.
    private func mergeSegments(width: CGFloat) -> some View {
        ForEach(Array(vm.mergeClips.enumerated()), id: \.element.id) { index, clip in
            let start = vm.mergeOffset(upTo: index)
            let xStart = x(for: start, width: width) + 1.5
            let xEnd = x(for: start + clip.duration, width: width) - 1.5
            let leadX = x(for: start + clip.trimStart, width: width)
            let trailX = x(for: start + clip.trimEnd, width: width)
            let isCurrent = vm.playingMergeIndex == index
            Group {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LinearGradient(colors: [Color.purple.opacity(isCurrent ? 0.9 : 0.7),
                                                      Color.purple.opacity(isCurrent ? 0.7 : 0.5)],
                                             startPoint: .top, endPoint: .bottom))
                    if xEnd - xStart > 26 {
                        VStack(spacing: 1) {
                            Text("\(index + 1)")
                                .font(.system(size: 10, weight: .bold))
                            if xEnd - xStart > 70 {
                                Text(TimeFormatting.clock(clip.trimmedDuration))
                                    .font(.system(size: 8, design: .monospaced))
                            }
                        }
                        .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .frame(width: max(3, xEnd - xStart), height: trackHeight)
                .position(x: (xStart + xEnd) / 2, y: trackHeight / 2)

                // Trimmed-away shading within this clip.
                if leadX > xStart + 1 {
                    Rectangle()
                        .fill(Color.black.opacity(0.55))
                        .frame(width: leadX - xStart, height: trackHeight)
                        .position(x: (xStart + leadX) / 2, y: trackHeight / 2)
                }
                if trailX < xEnd - 1 {
                    Rectangle()
                        .fill(Color.black.opacity(0.55))
                        .frame(width: xEnd - trailX, height: trackHeight)
                        .position(x: (trailX + xEnd) / 2, y: trackHeight / 2)
                }

                // Per-clip trim handles (trim mode).
                if vm.mode == .trim {
                    mergeHandle(at: leadX, isLead: true)
                    mergeHandle(at: trailX, isLead: false)
                }
            }
        }
    }

    /// Handles sit INSIDE their own clip (inset from the edge) so adjacent
    /// clips' handles never overlap at a shared boundary; the chevron points
    /// inward to show which clip the handle trims.
    private func mergeHandle(at xPos: CGFloat, isLead: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.white)
            .frame(width: 7, height: trackHeight + 4)
            .overlay(
                Image(systemName: isLead ? "chevron.right" : "chevron.left")
                    .font(.system(size: 6, weight: .black))
                    .foregroundStyle(Color.purple.opacity(0.9)))
            .shadow(radius: 1)
            .position(x: xPos + (isLead ? handleInset : -handleInset), y: trackHeight / 2)
    }

    private func cutRegions(width: CGFloat) -> some View {
        ForEach(vm.cuts) { cut in
            let xStart = x(for: cut.start, width: width)
            let xEnd = x(for: cut.end, width: width)
            let isSelected = vm.selectedCutID == cut.id
            ZStack {
                Rectangle()
                    .fill(Color.red.opacity(isSelected ? 0.85 : 0.6))
                if xEnd - xStart > 34 {
                    Text("CUT")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .frame(width: max(2, xEnd - xStart), height: trackHeight)
            .overlay(Rectangle().stroke(isSelected ? Color.white : Color.red.opacity(0.9), lineWidth: isSelected ? 2 : 1))
            .position(x: (xStart + xEnd) / 2, y: trackHeight / 2)
            .onTapGesture {
                vm.selectedCutID = cut.id
            }
        }
    }

    private func pendingCutOverlay(width: CGFloat) -> some View {
        Group {
            if let pending = pendingCut {
                let xStart = x(for: pending.start, width: width)
                let xEnd = x(for: pending.end, width: width)
                Rectangle()
                    .fill(Color.red.opacity(0.4))
                    .overlay(Rectangle().stroke(Color.red, style: StrokeStyle(lineWidth: 1, dash: [4])))
                    .frame(width: max(2, xEnd - xStart), height: trackHeight)
                    .position(x: (xStart + xEnd) / 2, y: trackHeight / 2)
            }
        }
    }

    private func trimShades(width: CGFloat) -> some View {
        Group {
            let leadX = x(for: vm.trimStart, width: width)
            let trailX = x(for: vm.trimEnd, width: width)
            let mainX = x(for: vm.duration, width: width)
            if leadX > 1 {
                Rectangle()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: leadX, height: trackHeight)
                    .position(x: leadX / 2, y: trackHeight / 2)
            }
            // Trim only shades the main video, never the merge segments.
            if trailX < mainX - 1 {
                Rectangle()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: mainX - trailX, height: trackHeight)
                    .position(x: trailX + (mainX - trailX) / 2, y: trackHeight / 2)
            }
        }
    }

    private func trimHandle(at seconds: Double, width: CGFloat, isLead: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.white)
            .frame(width: handleWidth, height: trackHeight + 8)
            .overlay(
                Image(systemName: isLead ? "chevron.right" : "chevron.left")
                    .font(.system(size: 7, weight: .black))
                    .foregroundStyle(Color.gray.opacity(0.8)))
            .shadow(radius: 1)
            .position(x: x(for: seconds, width: width) + (isLead ? handleInset : -handleInset),
                      y: trackHeight / 2)
    }

    @State private var audioDragBase: Double?

    /// Green bar showing where the background audio sits on the timeline —
    /// drag it to move the start point (in edited time).
    private func audioStrip(width: CGFloat) -> some View {
        let startT = vm.timelineTime(forEdited: vm.overlayAudioStart)
        let endT = vm.timelineTime(forEdited: min(vm.overlayAudioStart + vm.overlayEffectiveLength,
                                                  vm.totalEditedDuration))
        let x0 = x(for: startT, width: width)
        let x1 = max(x0 + 8, x(for: endT, width: width))
        return RoundedRectangle(cornerRadius: 3)
            .fill(Color.green.opacity(0.6))
            .overlay(
                HStack(spacing: 3) {
                    Image(systemName: vm.overlayAudioLoops ? "repeat" : "music.note")
                        .font(.system(size: 8, weight: .bold))
                    if x1 - x0 > 70 {
                        Text(vm.overlayAudioURL?.deletingPathExtension().lastPathComponent ?? "")
                            .font(.system(size: 9))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.white.opacity(0.95))
            )
            .frame(width: x1 - x0, height: 13)
            .position(x: (x0 + x1) / 2, y: trackHeight - 9)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if audioDragBase == nil { audioDragBase = vm.overlayAudioStart }
                        let delta = Double(value.translation.width / width) * vm.timelineDuration
                        let maxStart = max(0, vm.totalEditedDuration - 0.5)
                        vm.overlayAudioStart = min(max(0, (audioDragBase ?? 0) + delta), maxStart)
                    }
                    .onEnded { _ in audioDragBase = nil }
            )
            .help("Background audio — drag to move where it starts")
    }

    private func playheadMarker(width: CGFloat) -> some View {
        let xPos = x(for: vm.playhead, width: width)
        return VStack(spacing: 0) {
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 10))
                .foregroundStyle(.yellow)
            Rectangle()
                .fill(Color.yellow)
                .frame(width: 2, height: trackHeight + 10)
        }
        .position(x: xPos, y: (rulerHeight + trackHeight + 14) / 2 + 2)
        .allowsHitTesting(false)
    }

    // MARK: gesture

    private func timelineGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let t = time(at: value.location.x, width: width)
                if drag == nil {
                    drag = decideDrag(startX: value.startLocation.x, width: width)
                    switch drag {
                    case .trimLead, .trimTrail, .mergeTrimLead, .mergeTrimTrail:
                        vm.pushUndo()
                    default:
                        break
                    }
                }
                switch drag {
                case .seeking:
                    vm.seek(to: t)
                case .cutting(let anchor):
                    // Cuts exist only within the main video.
                    let clamped = min(t, vm.duration)
                    pendingCut = (min(anchor, clamped), max(anchor, clamped))
                case .trimLead:
                    vm.trimStart = min(max(0, t), vm.trimEnd - 0.1)
                case .trimTrail:
                    vm.trimEnd = max(min(vm.duration, t), vm.trimStart + 0.1)
                case .mergeTrimLead(let index):
                    vm.setMergeTrimStart(index: index, to: t - vm.mergeOffset(upTo: index))
                case .mergeTrimTrail(let index):
                    vm.setMergeTrimEnd(index: index, to: t - vm.mergeOffset(upTo: index))
                case nil:
                    break
                }
            }
            .onEnded { _ in
                if case .cutting = drag, let pending = pendingCut {
                    vm.addCut(start: pending.start, end: pending.end)
                }
                pendingCut = nil
                drag = nil
            }
    }

    private func decideDrag(startX: CGFloat, width: CGFloat) -> DragKind {
        let leadX = x(for: vm.trimStart, width: width) + handleInset
        let trailX = x(for: vm.trimEnd, width: width) - handleInset
        // Gather every handle with its distance and pick the CLOSEST one, so
        // a shared boundary (main end vs first clip start, or two adjacent
        // clips) resolves to the handle the user actually aimed at.
        var candidates: [(distance: CGFloat, kind: DragKind)] = [
            (abs(startX - leadX), .trimLead),
            (abs(startX - trailX), .trimTrail),
        ]
        if vm.mode == .trim {
            for (index, clip) in vm.mergeClips.enumerated() {
                let base = vm.mergeOffset(upTo: index)
                let clipLead = x(for: base + clip.trimStart, width: width) + handleInset
                let clipTrail = x(for: base + clip.trimEnd, width: width) - handleInset
                candidates.append((abs(startX - clipLead), .mergeTrimLead(index)))
                candidates.append((abs(startX - clipTrail), .mergeTrimTrail(index)))
            }
        }
        if let best = candidates.min(by: { $0.distance < $1.distance }),
           best.distance <= handleWidth {
            return best.kind
        }
        let anchor = time(at: startX, width: width)
        // Cut mode only applies within the main video; dragging over a merge
        // segment just seeks.
        return (vm.mode == .cut && anchor < vm.duration) ? .cutting(anchor: anchor) : .seeking
    }

    // MARK: mapping

    private func x(for seconds: Double, width: CGFloat) -> CGFloat {
        guard vm.timelineDuration > 0 else { return 0 }
        return CGFloat(seconds / vm.timelineDuration) * width
    }

    private func time(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(max(0, Double(x / width) * vm.timelineDuration), vm.timelineDuration)
    }

    private func niceStep(for duration: Double) -> Double {
        let candidates: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1200]
        for candidate in candidates where duration / candidate <= 12 {
            return candidate
        }
        return 1800
    }
}
