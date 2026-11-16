// Ported from Recorditor (ZRecorditor @7210322, native/MacRecorder/Editor/TimelineView.swift).
// Reworked: no modes. The edge handles always trim, dragging across the bar
// selects a stretch (Remove / Speed / Blur float above it), a click seeks,
// and effects sit in lanes under the bar.
import AVFoundation
import SwiftUI

struct EditorTimelineView: View {
    @EnvironmentObject private var vm: EditorViewModel
    @StateObject private var thumbs = TimelineThumbnails()

    @State private var drag: DragKind?
    @State private var dragMoved = false
    @State private var showSelectionSpeed = false
    @State private var laneBase: (start: Double, end: Double)?
    @State private var audioBase: (start: Double, clipStart: Double, clipEnd: Double)?
    @State private var lastScrollCenter: Double = -1

    private enum DragKind {
        case ignore
        case scrub
        case select(anchor: Double)
        case trimLead
        case trimTrail
        case mergeTrimLead(Int)
        case mergeTrimTrail(Int)
        case cutEdge(id: UUID, isLead: Bool)
    }

    private let pillRow: CGFloat = 28
    private let rulerHeight: CGFloat = 20
    private let trackHeight: CGFloat = 76
    private let handleWidth: CGFloat = 10
    /// Handles are inset into their clip so boundary neighbors don't overlap.
    private let handleInset: CGFloat = 5
    private let laneHeight: CGFloat = 20
    private let laneGap: CGFloat = 3

    private var trackTop: CGFloat { pillRow + rulerHeight + 2 }
    private var lanesTop: CGFloat { trackTop + trackHeight + 8 }

    // MARK: lanes plan

    /// Greedy interval packing so overlapping annotations get their own row.
    private func annotationRows() -> (rows: [UUID: Int], count: Int) {
        var ends: [Double] = []
        var rows: [UUID: Int] = [:]
        for item in vm.annotations.sorted(by: { $0.start < $1.start }) {
            if let free = ends.firstIndex(where: { $0 <= item.start + 0.01 }) {
                ends[free] = item.end
                rows[item.id] = free
            } else if ends.count < 3 {
                ends.append(item.end)
                rows[item.id] = ends.count - 1
            } else {
                rows[item.id] = 2
            }
        }
        return (rows, ends.count)
    }

    private var hasAudio: Bool { vm.overlayAudioURL != nil && vm.overlayClipLength > 0 }

    private func lanesHeight(annotationRowCount: Int) -> CGFloat {
        var rows = annotationRowCount
        if !vm.speedSegments.isEmpty { rows += 1 }
        if hasAudio { rows += 1 }
        return CGFloat(rows) * (laneHeight + laneGap)
    }

    private func totalHeight(annotationRowCount: Int) -> CGFloat {
        lanesTop + lanesHeight(annotationRowCount: annotationRowCount) + 6
    }

    var body: some View {
        let plan = annotationRows()
        let height = totalHeight(annotationRowCount: plan.count)
        GeometryReader { outer in
            let viewport = outer.size.width
            let width = max(viewport, viewport * vm.timelineZoom)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: vm.timelineZoom > 1) {
                    content(width: width, height: height, plan: plan)
                        .frame(width: width, height: height)
                }
                .scrollDisabled(vm.timelineZoom <= 1)
                .onChange(of: vm.timelineZoom) { _, _ in
                    DispatchQueue.main.async {
                        lastScrollCenter = vm.playhead
                        proxy.scrollTo("playhead", anchor: .center)
                    }
                }
                .onChange(of: vm.playhead) { _, now in
                    // Follow the playhead while playing in a zoomed bar.
                    guard vm.timelineZoom > 1, vm.isPlaying else { return }
                    let window = vm.timelineDuration / vm.timelineZoom
                    if lastScrollCenter < 0 || abs(now - lastScrollCenter) > window * 0.4 {
                        lastScrollCenter = now
                        proxy.scrollTo("playhead", anchor: .center)
                    }
                }
            }
            .task(id: thumbKey(width: width)) {
                await thumbs.prepare(url: vm.sourceURL, duration: vm.duration,
                                     count: thumbCount(width: width))
            }
        }
        .frame(height: height + (vm.timelineZoom > 1 ? 12 : 0))
        .padding(.horizontal, 10)
    }

    private func content(width: CGFloat, height: CGFloat,
                         plan: (rows: [UUID: Int], count: Int)) -> some View {
        ZStack(alignment: .topLeading) {
            ruler(width: width)
                .offset(y: pillRow)

            Group {
                track(width: width)
                mergeSegments(width: width)
                trimShades(width: width)
                cutRegions(width: width)
                selectionOverlay(width: width)
                trimHandle(at: vm.trimStart, width: width, isLead: true)
                trimHandle(at: vm.trimEnd, width: width, isLead: false)
            }

            lanes(width: width, plan: plan)

            // The scroll target for "follow the playhead".
            Color.clear
                .frame(width: 2, height: 2)
                .position(x: x(for: vm.playhead, width: width), y: height / 2)
                .id("playhead")
                .allowsHitTesting(false)

            playheadMarker(width: width, height: height)
            selectionPill(width: width)
        }
        .contentShape(Rectangle())
        .gesture(timelineGesture(width: width))
    }

    // MARK: pieces

    private func ruler(width: CGFloat) -> some View {
        let step = niceStep(width: width)
        let labelWidth: CGFloat = 40
        return ZStack(alignment: .topLeading) {
            ForEach(Array(stride(from: 0.0, through: vm.timelineDuration, by: step)), id: \.self) { t in
                let xPos = x(for: t, width: width)
                // The label is centred on its tick but kept inside the ruler,
                // so the first one reads "0:00", whole, not a clipped "00".
                let labelX = min(max(xPos, labelWidth / 2), max(labelWidth / 2, width - labelWidth / 2))
                Text(SessionDetailRules.clock(t))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: labelWidth)
                    .position(x: labelX, y: 5)
                Rectangle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 1, height: 5)
                    .position(x: xPos, y: rulerHeight - 3)
            }
        }
        .frame(height: rulerHeight)
    }

    private func track(width: CGFloat) -> some View {
        // Main video occupies [0, duration] of the virtual timeline.
        let mainWidth = max(2, x(for: vm.duration, width: width))
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return ZStack(alignment: .leading) {
            shape.fill(Color.primary.opacity(0.14))
            if thumbs.count > 0 {
                HStack(spacing: 0) {
                    ForEach(0..<thumbs.count, id: \.self) { index in
                        if let image = thumbs.images[index] {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: mainWidth / CGFloat(thumbs.count), height: trackHeight)
                                .clipped()
                        } else {
                            Color.clear.frame(width: mainWidth / CGFloat(thumbs.count), height: trackHeight)
                        }
                    }
                }
            }
        }
        .frame(width: mainWidth, height: trackHeight)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
        .position(x: mainWidth / 2, y: trackTop + trackHeight / 2)
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
            let midY = trackTop + trackHeight / 2
            Group {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(isCurrent ? 0.34 : 0.22))
                    if xEnd - xStart > 26 {
                        VStack(spacing: 1) {
                            Text("\(index + 1)")
                                .font(.system(size: 11, weight: .bold))
                            if xEnd - xStart > 70 {
                                Text(TimeFormatting.clock(clip.trimmedDuration))
                                    .font(.system(size: 9, design: .monospaced))
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
                .frame(width: max(3, xEnd - xStart), height: trackHeight)
                .position(x: (xStart + xEnd) / 2, y: midY)

                // Trimmed-away shading within this clip.
                if leadX > xStart + 1 {
                    Rectangle()
                        .fill(Color.black.opacity(0.55))
                        .frame(width: leadX - xStart, height: trackHeight)
                        .position(x: (xStart + leadX) / 2, y: midY)
                }
                if trailX < xEnd - 1 {
                    Rectangle()
                        .fill(Color.black.opacity(0.55))
                        .frame(width: xEnd - trailX, height: trackHeight)
                        .position(x: (trailX + xEnd) / 2, y: midY)
                }

                mergeHandle(at: leadX, isLead: true)
                mergeHandle(at: trailX, isLead: false)
            }
        }
    }

    /// Handles sit INSIDE their own clip (inset from the edge) so adjacent
    /// clips' handles never overlap at a shared boundary; the chevron points
    /// inward to show which clip the handle trims.
    private func mergeHandle(at xPos: CGFloat, isLead: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.primary.opacity(0.85))
            .frame(width: 7, height: trackHeight + 4)
            .overlay(
                Image(systemName: isLead ? "chevron.right" : "chevron.left")
                    .font(.system(size: 6, weight: .black))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor)))
            .shadow(radius: 1)
            .position(x: xPos + (isLead ? handleInset : -handleInset), y: trackTop + trackHeight / 2)
    }

    /// Removed stretches: hatched red, clickable to select, edges draggable.
    private func cutRegions(width: CGFloat) -> some View {
        ForEach(vm.cuts) { cut in
            let xStart = x(for: cut.start, width: width)
            let xEnd = x(for: cut.end, width: width)
            let isSelected = vm.selectedCutID == cut.id
            ZStack {
                Rectangle()
                    .fill(EditorTheme.danger.opacity(isSelected ? 0.5 : 0.36))
                Canvas { context, size in
                    var path = Path()
                    var offset: CGFloat = -size.height
                    while offset < size.width {
                        path.move(to: CGPoint(x: offset, y: size.height))
                        path.addLine(to: CGPoint(x: offset + size.height, y: 0))
                        offset += 8
                    }
                    context.stroke(path, with: .color(Color.white.opacity(0.35)), lineWidth: 1)
                }
                if xEnd - xStart > 60 {
                    Text("Removed")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 1)
                }
            }
            .frame(width: max(2, xEnd - xStart), height: trackHeight)
            .overlay(Rectangle().strokeBorder(isSelected ? Color.white : EditorTheme.danger,
                                              lineWidth: isSelected ? 2 : 1))
            .overlay(alignment: .leading) {
                if isSelected { cutGrip }
            }
            .overlay(alignment: .trailing) {
                if isSelected { cutGrip }
            }
            .position(x: (xStart + xEnd) / 2, y: trackTop + trackHeight / 2)
            .allowsHitTesting(false)
        }
    }

    private var cutGrip: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.white)
            .frame(width: 5, height: 24)
            .shadow(radius: 1)
    }

    private func selectionOverlay(width: CGFloat) -> some View {
        Group {
            if let selection = vm.selection {
                let xStart = x(for: selection.lowerBound, width: width)
                let xEnd = x(for: selection.upperBound, width: width)
                Rectangle()
                    .fill(Brand.green.opacity(0.28))
                    .overlay(Rectangle().strokeBorder(Brand.green, lineWidth: 1.5))
                    .frame(width: max(2, xEnd - xStart), height: trackHeight)
                    .position(x: (xStart + xEnd) / 2, y: trackTop + trackHeight / 2)
                    .allowsHitTesting(false)
            }
        }
    }

    private func trimShades(width: CGFloat) -> some View {
        Group {
            let leadX = x(for: vm.trimStart, width: width)
            let trailX = x(for: vm.trimEnd, width: width)
            let mainX = x(for: vm.duration, width: width)
            let midY = trackTop + trackHeight / 2
            if leadX > 1 {
                Rectangle()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: leadX, height: trackHeight)
                    .position(x: leadX / 2, y: midY)
            }
            // Trim only shades the main video, never the merge segments.
            if trailX < mainX - 1 {
                Rectangle()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: mainX - trailX, height: trackHeight)
                    .position(x: trailX + (mainX - trailX) / 2, y: midY)
            }
        }
        .allowsHitTesting(false)
    }

    private func trimHandle(at seconds: Double, width: CGFloat, isLead: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.primary.opacity(0.85))
            .frame(width: handleWidth, height: trackHeight + 8)
            .overlay(
                Image(systemName: isLead ? "chevron.right" : "chevron.left")
                    .font(.system(size: 7, weight: .black))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor)))
            .shadow(radius: 1)
            .position(x: x(for: seconds, width: width) + (isLead ? handleInset : -handleInset),
                      y: trackTop + trackHeight / 2)
            .allowsHitTesting(false)
    }

    // MARK: selection pill

    @ViewBuilder
    private func selectionPill(width: CGFloat) -> some View {
        if let selection = vm.selection {
            let mid = x(for: (selection.lowerBound + selection.upperBound) / 2, width: width)
            let pillWidth: CGFloat = 244
            HStack(spacing: 2) {
                pillButton("Remove", icon: "scissors") { vm.removeSelection() }
                    .help("Take this stretch out of the video (⌫)")
                pillButton("Speed", icon: "speedometer") { showSelectionSpeed.toggle() }
                    .popover(isPresented: $showSelectionSpeed, arrowEdge: .top) {
                        SpeedPopover(isPresented: $showSelectionSpeed)
                            .environmentObject(vm)
                    }
                    .help("Play this stretch faster or slower")
                pillButton("Blur", icon: "eye.slash") { vm.beginAnnotationPlacement(.blur) }
                    .help("Hide something on screen for this stretch (B)")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .greenroomGlass(in: Capsule(), interactive: true)
            .frame(width: pillWidth)
            .position(x: min(max(mid, pillWidth / 2), max(pillWidth / 2, width - pillWidth / 2)),
                      y: pillRow / 2)
        }
    }

    private func pillButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: lanes

    private func lanes(width: CGFloat, plan: (rows: [UUID: Int], count: Int)) -> some View {
        var yCursor = lanesTop
        let annotationTop = yCursor
        if !vm.annotations.isEmpty { yCursor += CGFloat(plan.count) * (laneHeight + laneGap) }
        let speedTop = yCursor
        if !vm.speedSegments.isEmpty { yCursor += laneHeight + laneGap }
        let audioTop = yCursor
        return ZStack(alignment: .topLeading) {
            ForEach(vm.annotations) { item in
                let row = CGFloat(plan.rows[item.id] ?? 0)
                laneBar(start: item.start, end: item.end, top: annotationTop + row * (laneHeight + laneGap),
                        width: width,
                        fill: Brand.green.opacity(0.55),
                        icon: item.kind == .blur ? "eye.slash" : item.kind == .text ? "textformat" : "arrow.up.right",
                        label: item.kind == .blur ? "Blur" : item.kind == .text ? (item.text.isEmpty ? "Text" : item.text) : "Arrow",
                        selected: vm.selectedAnnotationID == item.id,
                        onSelect: { vm.selectedAnnotationID = item.id; vm.selectedCutID = nil; vm.selectedSpeedID = nil },
                        onBegin: { vm.pushUndo() },
                        onChange: { vm.setAnnotationRange(id: item.id, start: $0, end: $1) })
            }
            ForEach(vm.speedSegments) { segment in
                laneBar(start: segment.start, end: segment.end, top: speedTop, width: width,
                        fill: Color.primary.opacity(0.3),
                        icon: segment.factor < 1 ? "tortoise.fill" : "hare.fill",
                        label: String(format: "%g×", segment.factor),
                        selected: vm.selectedSpeedID == segment.id,
                        onSelect: { vm.selectedSpeedID = segment.id; vm.selectedCutID = nil; vm.selectedAnnotationID = nil },
                        onBegin: { vm.pushUndo() },
                        onChange: { vm.setSpeedRange(id: segment.id, start: $0, end: $1) })
            }
            if hasAudio {
                audioLane(width: width, top: audioTop)
            }
        }
    }

    /// One draggable bar in a lane: the body moves it, the ends resize it.
    private func laneBar(start: Double, end: Double, top: CGFloat, width: CGFloat,
                         fill: Color, icon: String, label: String, selected: Bool,
                         onSelect: @escaping () -> Void,
                         onBegin: @escaping () -> Void,
                         onChange: @escaping (Double, Double) -> Void) -> some View {
        let x0 = x(for: start, width: width)
        let x1 = max(x0 + 10, x(for: end, width: width))
        let secondsPerPoint = vm.timelineDuration / Double(max(1, width))
        func begin() {
            if laneBase == nil {
                laneBase = (start, end)
                onBegin()
            }
        }
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(fill)
            .overlay(
                HStack(spacing: 3) {
                    Image(systemName: icon).font(.system(size: 9, weight: .bold))
                    if x1 - x0 > 56 {
                        Text(label).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                    }
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            )
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(selected ? Color.white : Color.primary.opacity(0.25), lineWidth: selected ? 2 : 0.5))
            .overlay(alignment: .leading) { laneEdge(begin: begin, onChange: { delta in
                guard let base = laneBase else { return }
                onChange(base.start + delta * secondsPerPoint, base.end)
            }) }
            .overlay(alignment: .trailing) { laneEdge(begin: begin, onChange: { delta in
                guard let base = laneBase else { return }
                onChange(base.start, base.end + delta * secondsPerPoint)
            }) }
            .frame(width: x1 - x0, height: laneHeight)
            .contentShape(Rectangle())
            .onTapGesture { onSelect() }
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        begin()
                        onSelect()
                        guard let base = laneBase else { return }
                        var delta = Double(value.translation.width) * secondsPerPoint
                        delta = max(-base.start, min(delta, vm.duration - base.end))
                        onChange(base.start + delta, base.end + delta)
                    }
                    .onEnded { _ in laneBase = nil }
            )
            .position(x: (x0 + x1) / 2, y: top + laneHeight / 2)
    }

    private func laneEdge(begin: @escaping () -> Void,
                          onChange: @escaping (CGFloat) -> Void) -> some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .overlay(RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.5)).frame(width: 2, height: 10))
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        begin()
                        onChange(value.translation.width)
                    }
                    .onEnded { _ in laneBase = nil }
            )
    }

    /// The background audio: drag to move where it starts, ends to use less
    /// or more of the file.
    private func audioLane(width: CGFloat, top: CGFloat) -> some View {
        let startT = vm.timelineTime(forEdited: vm.overlayAudioStart)
        let endT = vm.timelineTime(forEdited: min(vm.overlayAudioStart + vm.overlayEffectiveLength,
                                                  vm.totalEditedDuration))
        let x0 = x(for: startT, width: width)
        let x1 = max(x0 + 10, x(for: endT, width: width))
        let secondsPerPoint = vm.timelineDuration / Double(max(1, width))
        func begin() {
            if audioBase == nil {
                audioBase = (vm.overlayAudioStart, vm.overlayAudioClipStart, vm.overlayAudioClipEnd)
            }
        }
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Brand.green.opacity(0.8))
            .overlay(
                HStack(spacing: 3) {
                    Image(systemName: vm.overlayAudioLoops ? "repeat" : "music.note")
                        .font(.system(size: 9, weight: .bold))
                    if x1 - x0 > 70 {
                        Text(vm.overlayAudioURL?.deletingPathExtension().lastPathComponent ?? "")
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            )
            .overlay(alignment: .leading) {
                laneEdge(begin: begin, onChange: { delta in
                    guard let base = audioBase else { return }
                    let d = max(-min(base.start, base.clipStart),
                                min(Double(delta) * secondsPerPoint, base.clipEnd - base.clipStart - 0.5))
                    vm.overlayAudioStart = base.start + d
                    vm.overlayAudioClipStart = base.clipStart + d
                })
            }
            .overlay(alignment: .trailing) {
                laneEdge(begin: begin, onChange: { delta in
                    guard let base = audioBase else { return }
                    let wanted = base.clipEnd + Double(delta) * secondsPerPoint
                    vm.overlayAudioClipEnd = min(max(wanted, base.clipStart + 0.5),
                                                 max(vm.overlayAudioDuration, 0.5))
                })
            }
            .frame(width: x1 - x0, height: laneHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        begin()
                        guard let base = audioBase else { return }
                        let delta = Double(value.translation.width) * secondsPerPoint
                        let maxStart = max(0, vm.totalEditedDuration - 0.5)
                        vm.overlayAudioStart = min(max(0, base.start + delta), maxStart)
                    }
                    .onEnded { _ in audioBase = nil }
            )
            .help("Background audio: drag to move it, drag the ends to use less or more of it")
            .position(x: (x0 + x1) / 2, y: top + laneHeight / 2)
    }

    private func playheadMarker(width: CGFloat, height: CGFloat) -> some View {
        let xPos = x(for: vm.playhead, width: width)
        let lineTop = pillRow + 4
        return ZStack {
            Rectangle()
                .fill(Color.white)
                .frame(width: 2, height: trackTop + trackHeight + 6 - lineTop)
                .shadow(color: .black.opacity(0.5), radius: 1)
                .position(x: xPos, y: lineTop + (trackTop + trackHeight + 6 - lineTop) / 2)
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.primary)
                .shadow(color: .black.opacity(0.5), radius: 1)
                .position(x: xPos, y: lineTop + 4)
        }
        .allowsHitTesting(false)
    }

    // MARK: gesture

    private func timelineGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let t = time(at: value.location.x, width: width)
                if drag == nil {
                    drag = decideDrag(start: value.startLocation, width: width)
                    dragMoved = false
                    switch drag {
                    case .trimLead, .trimTrail, .mergeTrimLead, .mergeTrimTrail, .cutEdge:
                        vm.pushUndo()
                    default:
                        break
                    }
                }
                if hypot(value.translation.width, value.translation.height) > 3 { dragMoved = true }
                switch drag {
                case .scrub:
                    vm.seek(to: t)
                case .select(let anchor):
                    guard dragMoved else { return }
                    let clamped = min(max(t, 0), vm.duration)
                    vm.selection = min(anchor, clamped)...max(anchor, clamped)
                    vm.selectedCutID = nil
                case .trimLead:
                    vm.trimStart = min(max(0, t), vm.trimEnd - 0.1)
                case .trimTrail:
                    vm.trimEnd = max(min(vm.duration, t), vm.trimStart + 0.1)
                case .mergeTrimLead(let index):
                    vm.setMergeTrimStart(index: index, to: t - vm.mergeOffset(upTo: index))
                case .mergeTrimTrail(let index):
                    vm.setMergeTrimEnd(index: index, to: t - vm.mergeOffset(upTo: index))
                case .cutEdge(let id, let isLead):
                    if let cut = vm.cuts.first(where: { $0.id == id }) {
                        let clamped = min(max(t, 0), vm.duration)
                        if isLead {
                            vm.setCutRange(id: id, start: min(clamped, cut.end - 0.15), end: cut.end)
                        } else {
                            vm.setCutRange(id: id, start: cut.start, end: max(clamped, cut.start + 0.15))
                        }
                    }
                case .ignore, nil:
                    break
                }
            }
            .onEnded { _ in
                if case .select(let anchor) = drag {
                    if !dragMoved {
                        // A click: select the removed stretch under it, else seek.
                        if let cut = vm.cuts.first(where: { anchor >= $0.start && anchor <= $0.end }) {
                            vm.selectedCutID = cut.id
                            vm.selection = nil
                        } else {
                            vm.selection = nil
                            vm.selectedCutID = nil
                            vm.seek(to: anchor)
                        }
                    } else if let selection = vm.selection, selection.upperBound - selection.lowerBound < 0.15 {
                        vm.selection = nil
                    }
                }
                drag = nil
            }
    }

    private func decideDrag(start: CGPoint, width: CGFloat) -> DragKind {
        if start.y < pillRow { return .ignore }
        if start.y < trackTop - 2 { return .scrub }
        if start.y > trackTop + trackHeight + 6 { return .scrub }

        let startX = start.x
        let leadX = x(for: vm.trimStart, width: width) + handleInset
        let trailX = x(for: vm.trimEnd, width: width) - handleInset
        // Gather every handle with its distance and pick the CLOSEST one, so
        // a shared boundary (main end vs first clip start, or two adjacent
        // clips) resolves to the handle the user actually aimed at.
        var candidates: [(distance: CGFloat, kind: DragKind)] = [
            (abs(startX - leadX), .trimLead),
            (abs(startX - trailX), .trimTrail),
        ]
        for (index, clip) in vm.mergeClips.enumerated() {
            let base = vm.mergeOffset(upTo: index)
            let clipLead = x(for: base + clip.trimStart, width: width) + handleInset
            let clipTrail = x(for: base + clip.trimEnd, width: width) - handleInset
            candidates.append((abs(startX - clipLead), .mergeTrimLead(index)))
            candidates.append((abs(startX - clipTrail), .mergeTrimTrail(index)))
        }
        // Removed-stretch edges lose ties to the trim handles.
        for cut in vm.cuts {
            candidates.append((abs(startX - x(for: cut.start, width: width)) + 2, .cutEdge(id: cut.id, isLead: true)))
            candidates.append((abs(startX - x(for: cut.end, width: width)) + 2, .cutEdge(id: cut.id, isLead: false)))
        }
        if let best = candidates.min(by: { $0.distance < $1.distance }),
           best.distance <= handleWidth {
            return best.kind
        }
        let anchor = time(at: startX, width: width)
        // Selecting only applies within the main video; dragging over a merge
        // segment just seeks.
        return anchor < vm.duration ? .select(anchor: anchor) : .scrub
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

    /// Smallest step that keeps ruler labels about 70pt apart.
    private func niceStep(width: CGFloat) -> Double {
        let candidates: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1200, 1800]
        let duration = max(vm.timelineDuration, 0.1)
        for candidate in candidates where CGFloat(candidate / duration) * width >= 70 {
            return candidate
        }
        return 3600
    }

    // MARK: thumbnails

    private func thumbCount(width: CGFloat) -> Int {
        let mainWidth = vm.timelineDuration > 0 ? width * CGFloat(vm.duration / vm.timelineDuration) : width
        let tile = trackHeight * 16 / 9
        let raw = max(1, Int(ceil(mainWidth / tile)))
        return min(120, ((raw + 5) / 6) * 6)
    }

    private func thumbKey(width: CGFloat) -> String {
        "\(vm.sourceURL?.path ?? "")|\(thumbCount(width: width))"
    }
}

/// Frame thumbnails for the main bar, generated off the main thread and
/// cached per file and tile count.
@MainActor
final class TimelineThumbnails: ObservableObject {
    @Published private(set) var images: [Int: CGImage] = [:]
    /// The tile count `images` was generated for (0 = none yet).
    @Published private(set) var count = 0

    private static var cache: [String: [Int: CGImage]] = [:]
    private var loadedKey = ""

    func prepare(url: URL?, duration: Double, count wanted: Int) async {
        guard let url, duration > 0 else {
            images = [:]
            count = 0
            return
        }
        let key = "\(url.path)|\(wanted)"
        guard key != loadedKey else { return }
        if let cached = Self.cache[key] {
            loadedKey = key
            images = cached
            count = wanted
            return
        }
        // Wait out a burst of changes (window drags, zoom steps).
        try? await Task.sleep(nanoseconds: 250_000_000)
        if Task.isCancelled { return }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)
        let slack = CMTime(seconds: max(0.05, duration / Double(wanted) / 2), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = slack
        generator.requestedTimeToleranceAfter = slack

        var times: [CMTime] = []
        var indexByValue: [Int64: Int] = [:]
        for index in 0..<wanted {
            let time = CMTime(seconds: duration * (Double(index) + 0.5) / Double(wanted), preferredTimescale: 600)
            times.append(time)
            indexByValue[time.value] = index
        }

        var result: [Int: CGImage] = [:]
        var firstBatch = true
        for await item in generator.images(for: times) {
            if Task.isCancelled { generator.cancelAllCGImageGeneration(); return }
            if case .success(let requested, let image, _) = item, let index = indexByValue[requested.value] {
                result[index] = image
                // Swap in the new set as soon as a few tiles exist.
                if firstBatch, result.count >= 3 {
                    firstBatch = false
                    images = result
                    count = wanted
                } else if !firstBatch, result.count % 4 == 0 {
                    images = result
                }
            }
        }
        if Task.isCancelled { return }
        images = result
        count = wanted
        loadedKey = key
        if Self.cache.count > 6 { Self.cache.removeAll() }
        Self.cache[key] = result
    }
}
