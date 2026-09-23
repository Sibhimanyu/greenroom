//
//  ScreenroomReportView.swift
//  Greenroom
//
//  The report, as something worth looking at.
//
//  It used to live in the 320pt column beside the player, which is the right
//  width for a queue of notes and the wrong one for a report: the summary
//  wrapped to nine lines, the rubric was a list of numbers, and the speech
//  figures were four sentences of prose carrying numbers a chart would have
//  answered in a glance. So the report gets a window.
//
//  EVERY CHART HERE IS ONE SERIES. That is not a limitation, it is the
//  subject: this is one student's presentation, and a dashboard that reached
//  for a categorical palette would be colouring rows by their position in a
//  list. One series means one hue, no legend (the heading names it), and the
//  de-emphasis grey carries everything that is context rather than data.
//  Nothing here needs a colourblind-safety pass because nothing here asks a
//  reader to tell two colours apart.
//
//  What is deliberately NOT a chart:
//
//   - The readings are rows, sorted into "What to work on" and "What went
//     well", in the grammar Yoodli uses (see ScreenroomInsights). Each is a
//     name and a value said in words; opened, a tip, the evidence, a way to
//     hear it and where the talk sits against the others. They were dials,
//     then cards, then eight sections of detail below the map; the rows
//     hold all of it and show only what is asked for.
//   - A rubric line is a ratio against a limit, so it is a meter - a filled
//     track - rather than a bar on a shared axis. Five meters at five
//     different maxima on one axis would compare things that are not
//     comparable.
//   - The notes are marks on a time axis, not a series. They have no
//     magnitude; only position.
//   - Pace, filler rate and sentence length are read against a band rather
//     than against zero, so each card's meter is a marker on a track with the
//     comfortable range shaded. A bar chart of "your pace" would ask the
//     reader to compare one bar against nothing.
//   - Fillers, looking away and gesture all happen AT times, so each also
//     gets a strip along the same time axis. Where something clusters is
//     usually the finding; a total is only the headline.
//
//  Everything on this page that names a moment is clickable and moves the
//  recording there. A report that tells a student they said "basically"
//  thirty-one times and cannot show them one of them is a scolding, not
//  feedback.
//
//  Colour follows DESIGN.md exactly: `Brand.fill` (the logo's lime) for
//  fills, `Brand.text` for anything green with words in it, and no amber
//  anywhere - amber means "leaves your Mac" in this app and a rubric line is
//  not network traffic.
//
import Charts
import SwiftUI

struct ScreenroomReportView: View {
    @ObservedObject private var review = ScreenroomReviewController.shared
    /// Rows the teacher has opened or closed, flipping each one's default.
    @State private var toggled: Set<String> = []

    /// One column, capped and centred. A report is reading material; a
    /// dashboard stretched to 1600pt puts eleven words on a line.
    private static let column: CGFloat = 860

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if review.selected == nil {
                    empty
                } else {
                    header
                    // The readings as rows sorted into what to work on and
                    // what went well, then the map, then the summary. Every
                    // row says in words where it landed; its detail opens
                    // in place rather than living four screens down.
                    insightGroups
                    if hasMap { map }
                    if let analysis = review.analysis { prose(analysis) }
                    if review.scoring.markedCount > 0 { rubric }
                    if !review.notes.isEmpty { timeline }
                    if !review.notes.isEmpty { noteList }
                    if !review.words.isEmpty { transcript }
                    if !review.cohortFindings.isEmpty { consistency }
                    provenance
                }
            }
            .frame(maxWidth: Self.column, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .frame(minWidth: 720, minHeight: 600)
        .tint(Brand.green)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text("No presentation selected.")
                .font(.title3).foregroundStyle(.secondary)
            Text("Pick one in Sessions.")
                .font(.callout).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 400)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(review.selected?.presenter ?? "")
                    .font(.system(size: 30, weight: .bold))
                    .tracking(-0.6)
                HStack(spacing: 8) {
                    Text(review.selected?.presentedAt
                        .formatted(.dateTime.weekday(.wide).day().month(.wide).year()) ?? "")
                    if let ms = review.metrics?.durationMs, ms > 0 {
                        Text("\u{00B7}")
                        Text(Self.duration(ms)).monospacedDigit()
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 24)
            ScreenroomExportMenu(review: review)
        }
    }

    /// A number with a name, in the same shape as the reading cards at the
    /// top: the name first in plain words, then the number and what it is
    /// out of. It used to be a mono number over a lime capitals label, a
    /// second visual language for the same kind of fact.
    private func tile(_ value: String, _ label: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value)
                    .font(.system(size: 26, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let note {
                    Text(note)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1))
    }

    // MARK: Prose

    /// Headed like every other section, and held to a reading measure. At
    /// 17pt across the full column it ran to 130 characters a line with no
    /// heading, which read as a wall rather than a summary.
    private func prose(_ analysis: ScreenroomAnalysis) -> some View {
        section("IN SHORT") {
            VStack(alignment: .leading, spacing: 24) {
                if !analysis.summary.isEmpty {
                    Text(analysis.summary)
                        .font(.system(size: 15))
                        .lineSpacing(5)
                        .frame(maxWidth: 680, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            if !analysis.strengths.isEmpty || !analysis.workOn.isEmpty {
                HStack(alignment: .top, spacing: 32) {
                    bulletColumn("WHAT WORKED", analysis.strengths)
                    bulletColumn("WHAT TO CHANGE", analysis.workOn)
                }
            }
                if !analysis.patterns.isEmpty {
                    bulletColumn("ACROSS THE WHOLE THING", analysis.patterns)
                }
            }
        }
    }

    @ViewBuilder
    private func bulletColumn(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(0.8).foregroundStyle(.secondary)
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(Brand.fill).frame(width: 5, height: 5)
                            .offset(y: -2)
                        Text(item)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Rubric — meters, not bars

    private var rubric: some View {
        section("MARKS") {
            VStack(alignment: .leading, spacing: 20) {
                rubricShape()
                VStack(spacing: 14) {
                    ForEach(review.scoring.rubric.criteria) { criterion in
                        meter(criterion)
                    }
                }
            }
        }
    }

    /// Whether there is enough on one time axis to be worth drawing a map of.
    private var hasMap: Bool {
        guard review.metrics?.durationMs ?? 0 > 0 || !review.frames.isEmpty else { return false }
        let rows = (review.frames.isEmpty ? 0 : 1)
            + ((review.metrics?.paceWindow.isEmpty ?? true) ? 0 : 1)
            + ((review.metrics?.fillerCount ?? 0) > 0 ? 1 : 0)
            + ((review.presence?.sampleCount ?? 0) > 0 ? 1 : 0)
            + (review.notes.isEmpty ? 0 : 1)
        return rows >= 2
    }

    private func meter(_ criterion: ScreenroomCriterion) -> some View {
        let mark = review.scoring.score(for: criterion)
        let fraction = mark.score.map { Double($0) / Double(max(1, criterion.maxScore)) } ?? 0
        let average = groupAverage(for: criterion)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(criterion.title).font(.callout.weight(.medium))
                Spacer()
                Text(mark.score.map { "\($0)/\(criterion.maxScore)" } ?? "\u{2014}")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(mark.score == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(nsColor: .separatorColor).opacity(0.35))
                    Capsule().fill(Brand.fill)
                        .frame(width: max(0, geo.size.width * fraction))
                    // The group's average as a hairline, not a second series:
                    // one bar against a baseline, which is what "how does this
                    // compare" actually asks.
                    if let average, review.scoring.markedCount > 0 {
                        Rectangle()
                            .fill(Color(nsColor: .labelColor).opacity(0.55))
                            .frame(width: 1.5)
                            .offset(x: geo.size.width * average - 0.75)
                            .help("The group averages \(Int((average * 100).rounded()))% on this line.")
                    }
                }
            }
            .frame(height: 8)
            if !mark.comment.isEmpty {
                Text(mark.comment).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// This criterion's average across every other marked presentation, 0...1.
    private func groupAverage(for criterion: ScreenroomCriterion) -> Double? {
        let peers = ScreenroomLibrary.cohortEntries()
            .filter { $0.folder != review.selected?.folder }
            .compactMap { entry -> Double? in
                guard let match = entry.scoring.rubric.criteria.first(where: { $0.title == criterion.title }),
                      let value = entry.scoring.score(for: match).score,
                      match.maxScore > 0 else { return nil }
                return Double(value) / Double(match.maxScore)
            }
        guard peers.count >= 2 else { return nil }
        return peers.reduce(0, +) / Double(peers.count)
    }

    private func key(_ colour: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(colour).frame(width: 12, height: 8)
            Text(label)
        }
    }

    /// One tick per sample, drawn in a Canvas rather than as six hundred
    /// Rectangles. Clicking anywhere on it moves the recording there.
    private func presenceStrip(_ seen: ScreenroomPresence, height: CGFloat = 20) -> some View {
        let span = max(1.0, Double((seen.samples.last?.atMs ?? 0) + seen.everyMs))
        return GeometryReader { geo in
            Canvas { context, size in
                let width = max(1, size.width / CGFloat(max(1, seen.samples.count)))
                for sample in seen.samples {
                    let x = size.width * CGFloat(Double(sample.atMs) / span)
                    let colour: Color = sample.facing
                        ? Brand.fill
                        : (sample.face ? Color(nsColor: .labelColor).opacity(0.6)
                                       : Color(nsColor: .separatorColor).opacity(0.5))
                    context.fill(Path(CGRect(x: x, y: 0, width: width + 0.5, height: size.height)),
                                 with: .color(colour))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .gesture(SpatialTapGesture().onEnded { value in
                review.seek(toMs: Int(span * Double(value.location.x / max(1, geo.size.width))))
            })
        }
        .frame(height: height)
    }

    // MARK: The transcript, with the crutches marked

    /// Every word, broken where the speaker took a breath, with fillers
    /// highlighted and hedges underlined.
    ///
    /// The single most useful thing on this page, and the reason the verbatim
    /// transcriber matters: seeing "basically" eleven times in one paragraph
    /// does something a count of thirty-one never does. Click any stretch to
    /// hear it.
    private var transcript: some View {
        let m = review.metrics
        let fillerAt = Set((m?.verbatim ?? false) ? m?.fillers.flatMap(\.atMs) ?? [] : [])
        let hedgeAt = Set((m?.verbatim ?? false) ? m?.hedges.flatMap(\.atMs) ?? [] : [])
        let runs = (m?.runs.isEmpty ?? true) ? [] : m!.runs
        return section("TRANSCRIPT",
                       trailing: (m?.verbatim ?? false)
                           ? "fillers highlighted, hedges underlined \u{00B7} click to play"
                           : "click to play") {
            VStack(alignment: .leading, spacing: 10) {
                if !(m?.verbatim ?? false) {
                    Text("Tidied by the recogniser, so there are no crutch words left in it to mark. Transcribe with whisper for the verbatim version.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(runs.isEmpty ? [ScreenroomSpeechMetrics.Run(startMs: review.words.first?.atMs ?? 0, endMs: review.words.last?.endMs ?? 0, words: review.words.count, opener: "")] : runs) { run in
                    Button { review.seek(toMs: run.startMs, lead: 500) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(Self.clock(run.startMs / 1000))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                            Text(line(for: run, fillerAt: fillerAt, hedgeAt: hedgeAt))
                                .font(.system(size: 14))
                                .lineSpacing(3)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func line(for run: ScreenroomSpeechMetrics.Run,
                      fillerAt: Set<Int>, hedgeAt: Set<Int>) -> AttributedString {
        var out = AttributedString()
        for word in review.words where word.atMs >= run.startMs && word.atMs <= run.endMs {
            var piece = AttributedString(word.text + " ")
            if fillerAt.contains(word.atMs) {
                piece.foregroundColor = Brand.text
                piece.backgroundColor = Brand.fill.opacity(0.25)
                piece.font = .system(size: 14, weight: .semibold)
            } else if hedgeAt.contains(word.atMs) {
                piece.underlineStyle = .single
                piece.foregroundColor = .secondary
            }
            out += piece
        }
        return out
    }

    // MARK: Shared shapes

    /// A horizontal bar chart of counted words. One hue for every bar: bar
    /// length already carries the magnitude, and darkening the long ones
    /// would encode the same fact twice.
    @ViewBuilder
    private func wordBars(_ items: [ScreenroomSpeechMetrics.Filler], limit: Int) -> some View {
        let shown = Array(items.prefix(limit))
        let rest = items.dropFirst(limit)
        if items.count < 3 {
            // One or two bars is the one-bar bar chart this file's header
            // rules out: a full-width stripe to say "it's" three times.
            Text(items.map { "\u{201C}\($0.word)\u{201D} \($0.count == 1 ? "once" : "\($0.count) times")" }
                .joined(separator: ", ") + ".")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        } else {
        VStack(alignment: .leading, spacing: 8) {
            Chart(shown) { item in
                BarMark(x: .value("Times", item.count), y: .value("Word", item.word))
                    .foregroundStyle(Brand.fill)
                    .cornerRadius(4)
                    .annotation(position: .trailing, alignment: .leading) {
                        Text("\(item.count)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisValueLabel().font(.system(size: 11))
                }
            }
            .frame(height: CGFloat(shown.count) * 26 + 12)

            if !rest.isEmpty {
                Text("Also " + rest.map { "\u{201C}\($0.word)\u{201D} \($0.count)\u{00D7}" }
                    .joined(separator: ", ") + ".")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        }
    }

    /// Moments on the recording's time axis. No magnitude, only position -
    /// the same form the notes get, because it is the same kind of fact.
    @ViewBuilder
    private func strip(_ label: String, times: [Int]) -> some View {
        if !times.isEmpty {
            let span = max(Double(review.metrics?.durationMs ?? 0),
                           Double((times.max() ?? 0) + 1))
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                GeometryReader { geo in
                    Canvas { context, size in
                        context.fill(Path(roundedRect: CGRect(x: 0, y: size.height / 2 - 2,
                                                              width: size.width, height: 4),
                                          cornerRadius: 2),
                                     with: .color(Color(nsColor: .separatorColor).opacity(0.35)))
                        for at in times {
                            let x = size.width * CGFloat(Double(at) / span)
                            context.fill(Path(roundedRect: CGRect(x: x - 1, y: 0, width: 2.5, height: size.height),
                                              cornerRadius: 1.25),
                                         with: .color(Brand.fill))
                        }
                    }
                    .gesture(SpatialTapGesture().onEnded { value in
                        review.seek(toMs: Int(span * Double(value.location.x / max(1, geo.size.width))))
                    })
                }
                .frame(height: 18)
            }
        }
    }

    /// A clickable timestamp.
    private func timeChip(_ ms: Int) -> some View {
        Button { review.seek(toMs: ms) } label: {
            Text(Self.clock(ms / 1000))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Brand.text)
                .padding(.vertical, 2).padding(.horizontal, 5)
                .background(RoundedRectangle(cornerRadius: 4).fill(Brand.fill.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }


    // MARK: The map of the talk

    /// One picture of the whole presentation, on one time axis.
    ///
    /// This is the thing the page was missing. Every other section answers
    /// "how much" - how many fillers, what pace, how often facing the room -
    /// and all of them are totals. A total cannot show you that the pace
    /// climbed and the fillers arrived together at the eleven-minute mark,
    /// which is the moment the talk got away from them and the only thing
    /// worth working on next week.
    ///
    /// Everything below the filmstrip shares one x axis and one left gutter,
    /// so a column read downwards is one moment in the recording. Click
    /// anywhere to play from there.
    private var map: some View {
        let span = mapSpan
        return section("THE WHOLE TALK", trailing: "read a column downwards for one moment \u{00B7} click anywhere to play") {
            VStack(alignment: .leading, spacing: 8) {
                if !review.frames.isEmpty {
                    mapRow("") { filmstrip }
                }
                if let m = review.metrics, !m.paceWindow.isEmpty {
                    mapRow("Pace") { paceRibbon(m, span: span) }
                }
                if let m = review.metrics, m.fillerCount > 0 {
                    mapRow("Fillers") { tickRow(m.fillers.flatMap(\.atMs), span: span, height: 16) }
                }
                if let m = review.metrics, m.hedgeCount > 0 {
                    mapRow("Hedges") { tickRow(m.hedges.flatMap(\.atMs), span: span, height: 16) }
                }
                if let seen = review.presence, seen.sampleCount > 0 {
                    mapRow("Facing") { presenceStrip(seen, height: 16) }
                }
                if !review.notes.isEmpty {
                    mapRow("Notes") { tickRow(review.notes.map(\.atMs), span: span, height: 16) }
                }
                mapRow("") { mapAxis(span: span) }
                mapRow("") { mapKey }
            }
        }
    }

    /// The widest thing any strip has to cover, in milliseconds.
    private var mapSpan: Double {
        max(Double(review.metrics?.durationMs ?? 0),
            Double((review.notes.map(\.atMs).max() ?? 0) + 1),
            Double((review.presence?.samples.last?.atMs ?? 0) + 1),
            1)
    }

    /// A labelled row in the map. The gutter is fixed so every row - and the
    /// filmstrip above them - starts at the same x.
    private func mapRow<Content: View>(_ label: String,
                                       @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
            content()
        }
    }

    /// The stills, each at its own moment on the map's time axis.
    ///
    /// They used to share the width equally, so three stills from a short
    /// talk grew to a third of the column each and towered over every row
    /// below them, and none of them sat above the moment it was taken. Now
    /// each is one fixed size, centred on its timestamp and nudged inside the
    /// edges, so reading a column downwards still means one moment.
    private var filmstrip: some View {
        let wanted = 6
        let all = review.frames
        let step = max(1, all.count / wanted)
        let shown = stride(from: 0, to: all.count, by: step).prefix(wanted).map { all[$0] }
        let span = mapSpan
        return GeometryReader { geo in
            let cell = min(Self.stillWidth, geo.size.width / 5)
            ZStack(alignment: .topLeading) {
                ForEach(shown, id: \.self) { url in
                    let at = CGFloat(Double(Self.stamp(of: url)) / span)
                    Button { review.seek(toMs: Self.stamp(of: url), lead: 0) } label: {
                        Group {
                            if let image = NSImage(contentsOf: url) {
                                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                            } else {
                                Color(nsColor: .separatorColor).opacity(0.3)
                            }
                        }
                        .frame(width: cell, height: cell * 9 / 16)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .offset(x: min(max(0, geo.size.width * at - cell / 2), geo.size.width - cell))
                }
            }
        }
        .frame(height: Self.stillWidth * 9 / 16)
    }

    static let stillWidth: CGFloat = 120

    /// The moment a still was taken, read back off its own file name.
    ///
    /// ScreenroomFrames names them `003-01-20.jpg` - index, then minutes and
    /// seconds - precisely so that a thing holding only the file can say
    /// where it came from. Clicking a frame lands on that frame rather than
    /// on an estimate from its position in the row.
    static func stamp(of url: URL) -> Int {
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
        guard parts.count >= 3,
              let minutes = Int(parts[parts.count - 2]),
              let seconds = Int(parts[parts.count - 1]) else { return 0 }
        return (minutes * 60 + seconds) * 1_000
    }

    /// Pace as a ribbon rather than a line: one block per half-minute, its
    /// height the words per minute, on a FIXED scale with the comfortable
    /// band shaded behind it.
    ///
    /// It used to be scaled to its own peak, so the fastest window always
    /// hit the top and a talk at a steady 137 drew as one solid green slab
    /// that said nothing. Against a fixed scale and the band, a block that
    /// rises out of the shading is a stretch that ran fast, visibly.
    private func paceRibbon(_ m: ScreenroomSpeechMetrics, span: Double) -> some View {
        let band = ScreenroomSpeechMetrics.comfortablePace
        let top = max(260, m.paceWindow.map(\.wordsPerMinute).max() ?? 0)
        return GeometryReader { geo in
            Canvas { context, size in
                func y(_ wpm: Double) -> CGFloat { size.height * CGFloat(1 - wpm / top) }
                context.fill(Path(CGRect(x: 0, y: y(band.upperBound), width: size.width,
                                         height: y(band.lowerBound) - y(band.upperBound))),
                             with: .color(Brand.fill.opacity(0.12)))
                for window in m.paceWindow {
                    let x = size.width * CGFloat(Double(window.startMs) / span)
                    let next = size.width * CGFloat(min(span, Double(window.startMs + 30_000)) / span)
                    let rect = CGRect(x: x, y: y(window.wordsPerMinute),
                                      width: max(1, next - x - 2),
                                      height: size.height - y(window.wordsPerMinute))
                    let inside = band.contains(window.wordsPerMinute)
                    context.fill(Path(roundedRect: rect, cornerRadius: 2),
                                 with: .color(inside ? Brand.fill : Color(nsColor: .labelColor).opacity(0.6)))
                }
            }
            .gesture(SpatialTapGesture().onEnded { value in
                review.seek(toMs: Int(span * Double(value.location.x / max(1, geo.size.width))))
            })
        }
        .frame(height: 40)
        .help("Words per minute in each half-minute. Green is inside the comfortable 115\u{2013}180; grey is outside it.")
    }

    /// What the colours in the map mean. Said once, under it, rather than
    /// left for the reader to guess that two greys are two different things.
    private var mapKey: some View {
        HStack(spacing: 16) {
            key(Brand.fill, "pace in range \u{00B7} facing the room")
            key(Color(nsColor: .labelColor).opacity(0.6), "pace out of range \u{00B7} turned away")
            key(Color(nsColor: .separatorColor).opacity(0.5), "no face in shot")
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    /// Moments, as ticks on the shared axis.
    private func tickRow(_ times: [Int], span: Double, height: CGFloat) -> some View {
        GeometryReader { geo in
            Canvas { context, size in
                context.fill(Path(roundedRect: CGRect(x: 0, y: size.height / 2 - 1,
                                                      width: size.width, height: 2),
                                  cornerRadius: 1),
                             with: .color(Color(nsColor: .separatorColor).opacity(0.3)))
                for at in times {
                    let x = size.width * CGFloat(Double(at) / span)
                    context.fill(Path(roundedRect: CGRect(x: x - 1, y: 0, width: 2.5, height: size.height),
                                      cornerRadius: 1.25),
                                 with: .color(Brand.fill))
                }
            }
            .gesture(SpatialTapGesture().onEnded { value in
                review.seek(toMs: Int(span * Double(value.location.x / max(1, geo.size.width))))
            })
        }
        .frame(height: height)
    }

    private func mapAxis(span: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(Array(stride(from: 0.0, through: span, by: max(30_000, tickEvery(span)))), id: \.self) { at in
                    Text(Self.clock(Int(at / 1000)))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .offset(x: geo.size.width * CGFloat(at / span))
                }
            }
        }
        .frame(height: 14)
    }

    /// Six or so labels, on a round number of seconds.
    private func tickEvery(_ span: Double) -> Double {
        let rough = span / 6
        for step in [30_000.0, 60_000, 120_000, 300_000, 600_000, 900_000] where step >= rough {
            return step
        }
        return 1_800_000
    }

    // MARK: The readings, as rows

    /// Below this many breaths, "words per sentence" is the length of the
    /// whole recording: a 42-second clip read in one breath reported a
    /// 96-word sentence and "1 stretches of speech".
    static let enoughSentences = 3

    /// Set by the off-screen renderer so every row is drawn open. Never set
    /// in the app.
    nonisolated(unsafe) static var expandAll = false

    /// One reading. The shape is the one Yoodli settled on, studied from its
    /// own published screenshots: a name, the value said the way a person
    /// would say it, and - opened - one sentence to act on, the evidence, a
    /// way to hear it, and where the talk sits against the others.
    fileprivate struct Insight: Identifiable {
        let id: String
        let name: String
        let value: String
        let good: Bool
        let tip: String
        var detail: AnyView? = nil
        var action: (label: String, run: () -> Void)? = nil
        var standing: String? = nil
    }

    /// Two groups, sorted by the result rather than by the metric: the same
    /// row sits under "went well" in one talk and "to work on" in the next,
    /// so the teacher sees where everything landed before opening anything.
    ///
    /// These replace the reading cards and eight detail sections that used
    /// to follow the map. The detail is still all here; it is one click
    /// away instead of four screens down.
    @ViewBuilder
    private var insightGroups: some View {
        let all = insights
        let well = all.filter(\.good)
        let work = all.filter { !$0.good }
        if !all.isEmpty {
            VStack(alignment: .leading, spacing: 28) {
                if !work.isEmpty {
                    insightGroup("What to work on", symbol: "flag.fill", work, openFirst: true)
                }
                if !well.isEmpty {
                    insightGroup("What went well", symbol: "checkmark.circle.fill", well,
                                 openFirst: work.isEmpty)
                }
            }
        }
    }

    private func insightGroup(_ title: String, symbol: String, _ items: [Insight],
                              openFirst: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(title).font(.system(size: 16, weight: .semibold))
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(symbol == "flag.fill" ? AnyShapeStyle(.primary) : AnyShapeStyle(Brand.text))
            }
            .padding(.bottom, 2)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                insightRow(item, openByDefault: openFirst && index == 0)
            }
        }
    }

    private func insightRow(_ item: Insight, openByDefault: Bool) -> some View {
        // Toggling flips the default rather than setting a state, so the one
        // row that opens itself can still be closed.
        let isOpen = Self.expandAll || (openByDefault != toggled.contains(item.id))
        return VStack(spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.25)) {
                    if toggled.contains(item.id) { toggled.remove(item.id) } else { toggled.insert(item.id) }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 12)
                    Text(item.name)
                        .font(.system(size: 14, weight: .medium))
                    Spacer(minLength: 16)
                    Text(item.value)
                        .font(.system(size: 14, weight: .semibold))
                        .monospacedDigit()
                        // Green only where it went well: a green "No pauses"
                        // under "What to work on" read as praise.
                        .foregroundStyle(item.good ? AnyShapeStyle(Brand.text) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                Divider().opacity(0.6)
                VStack(spacing: 16) {
                    Text(item.tip)
                        .font(.system(size: 13))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Brand.fill.opacity(0.10)))
                    if let detail = item.detail { detail }
                    if let action = item.action {
                        Button(action: action.run) {
                            Label(action.label, systemImage: "play.circle.fill")
                        }
                        .buttonStyle(.bordered)
                    }
                    if let standing = item.standing {
                        Text(standing)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(16)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(isOpen ? AnyShapeStyle(Brand.fill.opacity(0.7))
                                 : AnyShapeStyle(Color(nsColor: .separatorColor).opacity(0.5)),
                          lineWidth: 1))
    }

    // MARK: What each row says

    private var insights: [Insight] {
        var out: [Insight] = []
        let words = review.words
        let peers = review.peerMetrics
        func percent(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }

        if let m = review.metrics, m.wordCount > 0 {
            let band = ScreenroomSpeechMetrics.comfortablePace
            let wpm = m.wordsPerMinute
            let curve = ScreenroomInsights.paceCurve(words, durationMs: m.durationMs)
            let fast = wpm > band.upperBound, slow = wpm < band.lowerBound
            var pace = Insight(
                id: "pace", name: "Pacing", value: "\(Int(wpm.rounded())) words/minute",
                good: !fast && !slow,
                tip: fast ? "Your pace was fast. Try speaking slower than \(Int(band.upperBound)) words a minute."
                    : slow ? "Your pace was slow. Try speaking faster than \(Int(band.lowerBound)) words a minute."
                    : "Your pace sounded comfortable, inside \(Int(band.lowerBound))\u{2013}\(Int(band.upperBound)) words a minute.",
                detail: AnyView(paceDetail(m, curve: curve)),
                standing: ScreenroomInsights.standing(wpm, among: peers.map(\.wordsPerMinute),
                                                     higher: "faster", lower: "slower"))
            if fast || slow {
                // From the stretch that most needs hearing: the fastest for a
                // fast talker, the slowest for a slow one.
                let pick = fast ? curve.max { $0.wordsPerMinute < $1.wordsPerMinute }
                                : curve.min { $0.wordsPerMinute < $1.wordsPerMinute }
                let from = max(0, Int(((pick?.seconds ?? 0) - 5) * 1000))
                let rate: Float = fast ? 0.75 : 1.25
                pace.action = ("Play from \(Self.clock(from / 1000)) at \(fast ? "0.75" : "1.25")\u{00D7} speed",
                               { review.play(fromMs: from, rate: rate) })
            }
            out.append(pace)

            if m.verbatim {
                let share = Double(m.fillerCount) / Double(m.wordCount)
                out.append(Insight(
                    id: "fillers", name: "Filler words",
                    value: m.fillerCount == 0 ? "None" : "\(m.fillerCount) filler\(m.fillerCount == 1 ? "" : "s"), \(percent(share))",
                    good: share <= ScreenroomInsights.fillerShare,
                    tip: m.fillerCount == 0 ? "Nice work. You didn\u{2019}t use any filler words."
                        : share <= ScreenroomInsights.fillerShare ? "Under 3% of words. A pause instead of a filler keeps it there."
                        : "Try getting under 3% by pausing instead.",
                    detail: m.fillerCount == 0 ? nil : AnyView(fillerDetail(m)),
                    standing: ScreenroomInsights.standing(
                        share, among: peers.filter(\.verbatim).map { Double($0.fillerCount) / Double(max(1, $0.wordCount)) },
                        higher: "more fillers", lower: "fewer fillers")))

                let softShare = Double(m.hedgeCount) / Double(m.wordCount)
                out.append(Insight(
                    id: "softeners", name: "Softening words",
                    value: m.hedgeCount == 0 ? "None" : "\(m.hedgeCount) softener\(m.hedgeCount == 1 ? "" : "s"), \(percent(softShare))",
                    good: softShare <= ScreenroomInsights.softenerShare,
                    tip: m.hedgeCount == 0 ? "No softeners. Every claim was said as if it was meant."
                        : softShare <= ScreenroomInsights.softenerShare ? "Under 4% of words, so claims still sounded sure."
                        : "Try cutting a few. Without them a claim sounds sure and says the same thing.",
                    detail: m.hedgeCount == 0 ? nil : AnyView(countedWords(m.hedges))))
            } else {
                out.append(Insight(
                    id: "fillers", name: "Filler words", value: "Not counted", good: false,
                    tip: "This transcript was tidied by the recogniser, so there were no fillers left in it to count. Transcribe with whisper to count them."))
            }

            let repeats = ScreenroomInsights.repeats(in: words)
            if !words.isEmpty {
                let share = Double(repeats.count) / Double(m.wordCount)
                out.append(Insight(
                    id: "repetition", name: "Repetition",
                    value: repeats.first.map { repeats.count == 1 ? "\u{201C}\($0.phrase)\u{201D}" : "\u{201C}\($0.phrase)\u{201D} +\(repeats.count - 1)" } ?? "None",
                    good: share <= ScreenroomInsights.repetitionShare,
                    tip: repeats.isEmpty ? "No restarts. Each sentence was said once."
                        : share <= ScreenroomInsights.repetitionShare ? "A few restarts, under 4% of words. That is ordinary speech."
                        : "Restarts usually mean the next sentence was not ready yet. A pause buys the same time.",
                    detail: repeats.isEmpty ? nil : AnyView(momentList(repeats.prefix(8).map { ($0.phrase, $0.atMs) }))))
            }

            if m.runs.count >= Self.enoughSentences, m.wordsPerRun > 0 {
                let band = ScreenroomInsights.sentenceBand
                let long = m.wordsPerRun > band.upperBound, short = m.wordsPerRun < band.lowerBound
                out.append(Insight(
                    id: "sentences", name: "Sentence length",
                    value: "\(Int(m.wordsPerRun.rounded())) words a breath",
                    good: !long && !short,
                    tip: long ? "Longer than usual. Try ending sentences sooner; the breath is where a listener catches up."
                        : short ? "Shorter than usual. Try joining a few thoughts so the talk flows."
                        : "In the usual range of 8\u{2013}20 words between breaths.",
                    detail: AnyView(HStack(spacing: 8) {
                        Text("Longest without a breath: \(String(format: "%.0f", Double(m.longestRunMs) / 1000))s")
                            .font(.callout)
                        timeChip(m.longestRunStartMs)
                    })))
            }

            if m.runs.count >= 6, let top = m.starters.first {
                let share = Double(top.count) / Double(m.runs.count)
                out.append(Insight(
                    id: "openers", name: "Sentence starters",
                    value: "\u{201C}\(top.word)\u{201D} \(percent(share))",
                    good: share < ScreenroomInsights.openerShare,
                    tip: share < ScreenroomInsights.openerShare ? "Sentences opened in different ways."
                        : "\u{201C}\(top.word)\u{201D} opened \(percent(share)) of sentences. Over 15% on one word sounds like a missing transition; a pause works instead.",
                    detail: AnyView(wordBars(m.starters, limit: 6))))
            }

            if m.vocabulary > 0 {
                out.append(Insight(
                    id: "vocabulary", name: "Vocabulary",
                    value: "\(percent(m.vocabulary)) varied",
                    good: m.vocabulary >= 0.5,
                    tip: m.vocabulary >= 0.5 ? "\(m.uniqueWords) different words out of \(m.wordCount) spoken."
                        : "Many words came round again. Try a different word for the second mention.",
                    detail: m.repeated.isEmpty ? nil : AnyView(VStack(alignment: .leading, spacing: 6) {
                        subhead("LEANED ON MOST \u{00B7} COMMON WORDS EXCLUDED")
                        wordBars(m.repeated, limit: 8)
                    }.frame(maxWidth: .infinity, alignment: .leading)),
                    standing: ScreenroomInsights.standing(m.vocabulary, among: peers.map(\.vocabulary),
                                                         higher: "more varied", lower: "less varied")))
            }

            out.append(Insight(
                id: "pauses", name: "Pauses",
                value: m.pauses.isEmpty ? "No pauses" : "\(m.pauses.count) pause\(m.pauses.count == 1 ? "" : "s")",
                good: m.talkRatio <= ScreenroomInsights.talkCeiling,
                tip: m.talkRatio <= ScreenroomInsights.talkCeiling ? "Pauses left room for each point to land."
                    : "Talking \(percent(m.talkRatio)) of the time. Try a one-second pause after each point, so it lands.",
                detail: AnyView(airTimeDetail(m))))

            if !words.isEmpty {
                let asked = ScreenroomInsights.questions(in: words)
                out.append(Insight(
                    id: "questions", name: "Questions",
                    value: asked.isEmpty ? "None" : "\(asked.count)",
                    good: true,
                    tip: asked.isEmpty ? "No questions asked. A question to the room is the quickest way to bring it back."
                        : "Every question asked, in order.",
                    detail: asked.isEmpty ? nil : AnyView(momentList(asked.map { ($0.text, $0.atMs) }))))
            }

            if m.verbatim, !m.careful.isEmpty {
                out.append(Insight(
                    id: "careful", name: "Worth a second look",
                    value: "\(m.careful.count) word\(m.careful.count == 1 ? "" : "s")",
                    good: false,
                    tip: "Not errors, and not scored. Words a second reader might want to check.",
                    detail: AnyView(countedWords(m.careful))))
            }
        }

        if let seen = review.presence, seen.sampleCount > 0 {
            let good = seen.facingRatio >= ScreenroomInsights.facingFloor
            out.append(Insight(
                id: "facing", name: "Facing the room",
                value: "\(percent(seen.facingRatio))",
                good: good,
                tip: good ? "Facing the room most of the time."
                    : "Turned away for most of the talk. Look up at the start of each new point.",
                detail: AnyView(facingDetail(seen)),
                standing: ScreenroomInsights.standing(seen.facingRatio,
                                                     among: review.peerPresence.map(\.facingRatio),
                                                     higher: "facing the room more", lower: "facing the room less")))
        }
        return out
    }

    // MARK: Row details

    /// A half-dial, the pace line and one sentence under it.
    ///
    /// The dial is the one place a gauge earns its keep: pace is read
    /// against slow and fast, not against zero. The words sit OUTSIDE the
    /// arc - the old dials put an 8pt caption inside the ring and it
    /// collided with the stroke.
    private func paceDetail(_ m: ScreenroomSpeechMetrics,
                            curve: [ScreenroomInsights.PacePoint]) -> some View {
        VStack(spacing: 18) {
            paceGauge(m.wordsPerMinute)
            if curve.count >= 3 {
                VStack(spacing: 8) {
                    Text("Pace through the talk")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    paceCurve(curve, durationMs: m.durationMs)
                    Text("**Vary your pace** to keep a room with you. **Practise the stretches** where it runs flat.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private static let gaugeScale: ClosedRange<Double> = 60...240

    private func paceGauge(_ wpm: Double) -> some View {
        let band = ScreenroomSpeechMetrics.comfortablePace
        let scale = Self.gaugeScale
        func at(_ x: Double) -> Double {
            min(1, max(0, (x - scale.lowerBound) / (scale.upperBound - scale.lowerBound)))
        }
        let inside = band.contains(wpm)
        return VStack(spacing: 2) {
            ZStack {
                Canvas { context, size in
                    let centre = CGPoint(x: size.width / 2, y: size.height - 6)
                    let radius = min(size.width / 2, size.height) - 12
                    func arc(_ from: Double, _ to: Double) -> Path {
                        var p = Path()
                        p.addArc(center: centre, radius: radius,
                                 startAngle: .degrees(180 + 180 * from),
                                 endAngle: .degrees(180 + 180 * to), clockwise: false)
                        return p
                    }
                    context.stroke(arc(0, 1), with: .color(Color(nsColor: .separatorColor).opacity(0.6)),
                                   style: StrokeStyle(lineWidth: 12, lineCap: .butt))
                    context.stroke(arc(at(band.lowerBound), at(band.upperBound)),
                                   with: .color(Brand.fill.opacity(0.45)),
                                   style: StrokeStyle(lineWidth: 12, lineCap: .butt))
                    // The needle, from the hub to just inside the arc.
                    let angle = Double.pi * (1 + at(wpm))
                    let tip = CGPoint(x: centre.x + cos(angle) * (radius - 4),
                                      y: centre.y + sin(angle) * (radius - 4))
                    var needle = Path()
                    needle.move(to: centre)
                    needle.addLine(to: tip)
                    let ink = inside ? Brand.fill : Color(nsColor: .labelColor)
                    context.stroke(needle, with: .color(ink), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    context.fill(Path(ellipseIn: CGRect(x: centre.x - 5, y: centre.y - 5, width: 10, height: 10)),
                                 with: .color(ink))
                }
                .frame(width: 200, height: 108)
                // The three words, outside the arc.
                Text("Comfortable").offset(y: -66)
                Text("Slow").rotationEffect(.degrees(-60)).offset(x: -90, y: -34)
                Text("Fast").rotationEffect(.degrees(60)).offset(x: 90, y: -34)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 260, height: 124)
            Text("\(Int(wpm.rounded()))")
                .font(.system(size: 30, weight: .semibold))
                .monospacedDigit()
        }
    }

    /// The pace line, broken wherever the speaker went quiet, over the
    /// comfortable band on a fixed scale.
    private func paceCurve(_ curve: [ScreenroomInsights.PacePoint], durationMs: Int) -> some View {
        let band = ScreenroomSpeechMetrics.comfortablePace
        let scale = Self.gaugeScale
        return Chart {
            RectangleMark(xStart: .value("From", 0), xEnd: .value("To", Double(durationMs) / 1000),
                          yStart: .value("Slow", band.lowerBound), yEnd: .value("Fast", band.upperBound))
                .foregroundStyle(Brand.fill.opacity(0.14))
            ForEach(curve, id: \.self) { point in
                LineMark(x: .value("At", point.seconds),
                         y: .value("Words per minute", min(scale.upperBound, max(scale.lowerBound, point.wordsPerMinute))),
                         series: .value("Stretch", point.segment))
                    .foregroundStyle(Brand.fill)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXScale(domain: 0...max(1, Double(durationMs) / 1000))
        .chartYScale(domain: scale)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(Color(nsColor: .separatorColor).opacity(0.4))
                AxisValueLabel {
                    if let s = value.as(Double.self) {
                        Text(Self.clock(Int(s))).font(.system(size: 11, design: .monospaced))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [60, 150, 240]) { value in
                AxisGridLine().foregroundStyle(Color(nsColor: .separatorColor).opacity(0.4))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v))").font(.system(size: 11, design: .monospaced))
                    }
                }
            }
        }
        .frame(height: 160)
    }

    private func fillerDetail(_ m: ScreenroomSpeechMetrics) -> some View {
        VStack(spacing: 16) {
            countedWords(m.fillers)
            strip("every one of them, in order \u{00B7} click to play", times: m.fillers.flatMap(\.atMs))
            fillerHeat(m)
        }
    }

    /// "um (20)   uh (18)   like (4)" - the word, then how many, spread
    /// across the row. Past six the tail goes into a sentence.
    private func countedWords(_ items: [ScreenroomSpeechMetrics.Filler]) -> some View {
        let shown = Array(items.prefix(6))
        let rest = items.dropFirst(6)
        return VStack(spacing: 8) {
            HStack(spacing: 0) {
                ForEach(shown) { item in
                    Button { review.seek(toMs: item.atMs.first ?? 0) } label: {
                        Text("\(item.word) (\(item.count))")
                            .font(.system(size: 14))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .help("Play the first one.")
                }
            }
            if !rest.isEmpty {
                Text("Also " + rest.map { "\u{201C}\($0.word)\u{201D} \($0.count)\u{00D7}" }.joined(separator: ", ") + ".")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// A list of moments: what was said, and a chip that plays it.
    private func momentList(_ items: [(String, Int)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    timeChip(item.1)
                    Text(item.0)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func airTimeDetail(_ m: ScreenroomSpeechMetrics) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 3).fill(Brand.fill)
                        .frame(width: max(2, geo.size.width * m.talkRatio))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(nsColor: .separatorColor).opacity(0.5))
                }
            }
            .frame(height: 14)
            HStack {
                key(Brand.fill, "talking \(Int((m.talkRatio * 100).rounded()))%")
                key(Color(nsColor: .separatorColor).opacity(0.5), "silence \(Int(((1 - m.talkRatio) * 100).rounded()))%")
                Spacer()
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            if !m.pauses.isEmpty {
                subhead("LONGEST PAUSES")
                HStack(spacing: 6) {
                    ForEach(m.pauses.prefix(8)) { pause in
                        Button { review.seek(toMs: pause.startMs) } label: {
                            VStack(spacing: 1) {
                                Text(String(format: "%.1fs", Double(pause.lengthMs) / 1000))
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                Text(Self.clock(pause.startMs / 1000))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 5).padding(.horizontal, 8)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .textBackgroundColor)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// Head angle, not gaze - said on the row itself, because a number
    /// labelled eye contact that cannot see eyes is the kind of thing a
    /// student repeats in an interview.
    private func facingDetail(_ seen: ScreenroomPresence) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            presenceStrip(seen, height: 14)
            HStack(spacing: 14) {
                key(Brand.fill, "facing the room")
                key(Color(nsColor: .labelColor).opacity(0.6), "turned away")
                key(Color(nsColor: .separatorColor).opacity(0.5), "no face in shot")
                Spacer()
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Text("In shot \(Int((seen.onCameraRatio * 100).rounded()))% of the time")
                if let ratio = seen.gestureRatio {
                    Text("Hands up \(Int((ratio * 100).rounded()))%")
                }
                Spacer()
            }
            .font(.callout)
            if let away = seen.longestAway {
                HStack(spacing: 8) {
                    Text("Longest stretch turned away: \(String(format: "%.0f", Double(away.lengthMs) / 1000))s")
                        .font(.callout)
                    timeChip(away.startMs)
                }
            }
            if !seen.sawBody {
                Text("No gesture figures: the framing is too tight to find a body. Record from further back.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Measured from head angle every \(seen.everyMs / 1000) seconds by Vision on this Mac. Not eye contact \u{2014} nothing here can see where the eyes pointed.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func subhead(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }

    // MARK: The rubric as a shape

    /// The marks as a polygon over the group's.
    ///
    /// Five meters answer "what did they get on each line". They do not
    /// answer "what shape is this student", which is the question a teacher
    /// asks across a term, and a shape is the only thing that answers it in
    /// one look. The meters stay underneath for the exact numbers; this is
    /// for the glance.
    @ViewBuilder
    private func rubricShape() -> some View {
        let criteria = review.scoring.rubric.criteria
        if criteria.count >= 3 {
            let mine: [Double] = criteria.map { criterion in
                guard let score = review.scoring.score(for: criterion).score,
                      criterion.maxScore > 0 else { return 0 }
                return Double(score) / Double(criterion.maxScore)
            }
            let group: [Double?] = criteria.map { groupAverage(for: $0) }
            HStack(alignment: .center, spacing: 20) {
                Canvas { context, size in
                    let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                    let radius = min(size.width, size.height) / 2 - 4
                    func point(_ index: Int, _ fraction: Double) -> CGPoint {
                        let angle = -Double.pi / 2 + 2 * .pi * Double(index) / Double(criteria.count)
                        return CGPoint(x: centre.x + cos(angle) * radius * fraction,
                                       y: centre.y + sin(angle) * radius * fraction)
                    }
                    // The web: four rings and a spoke per line.
                    for ring in [0.25, 0.5, 0.75, 1.0] {
                        var path = Path()
                        for index in 0..<criteria.count {
                            let p = point(index, ring)
                            index == 0 ? path.move(to: p) : path.addLine(to: p)
                        }
                        path.closeSubpath()
                        context.stroke(path, with: .color(Color(nsColor: .separatorColor).opacity(0.4)),
                                       lineWidth: ring == 1.0 ? 1 : 0.5)
                    }
                    for index in 0..<criteria.count {
                        var spoke = Path()
                        spoke.move(to: centre)
                        spoke.addLine(to: point(index, 1))
                        context.stroke(spoke, with: .color(Color(nsColor: .separatorColor).opacity(0.3)),
                                       lineWidth: 0.5)
                    }
                    // The group, as a dashed outline behind. Context, not a
                    // second series competing for the eye.
                    if group.allSatisfy({ $0 != nil }) {
                        var path = Path()
                        for index in 0..<criteria.count {
                            let p = point(index, group[index] ?? 0)
                            index == 0 ? path.move(to: p) : path.addLine(to: p)
                        }
                        path.closeSubpath()
                        context.stroke(path, with: .color(Color(nsColor: .labelColor).opacity(0.4)),
                                       style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                    // This student.
                    var path = Path()
                    for index in 0..<criteria.count {
                        let p = point(index, mine[index])
                        index == 0 ? path.move(to: p) : path.addLine(to: p)
                    }
                    path.closeSubpath()
                    context.fill(path, with: .color(Brand.fill.opacity(0.28)))
                    context.stroke(path, with: .color(Brand.fill), lineWidth: 2)
                    for index in 0..<criteria.count {
                        let p = point(index, mine[index])
                        context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)),
                                     with: .color(Brand.fill))
                    }
                }
                .frame(width: 190, height: 190)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(criteria.enumerated()), id: \.element.id) { index, criterion in
                        HStack(spacing: 6) {
                            Circle().fill(Brand.fill).frame(width: 5, height: 5)
                            Text(criterion.title).font(.caption)
                            Spacer(minLength: 8)
                            Text("\(Int((mine[index] * 100).rounded()))%")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if group.allSatisfy({ $0 != nil }) {
                        HStack(spacing: 6) {
                            Rectangle().fill(Color(nsColor: .labelColor).opacity(0.4))
                                .frame(width: 10, height: 1)
                            Text("the group").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Fillers by the minute

    /// A block per minute, darker where more of them landed.
    ///
    /// The bar chart says which crutch; the strip says when each one was.
    /// Neither says "the last four minutes were three times worse than the
    /// first ten", which is the shape of somebody running out of script, and
    /// a grid of blocks says it without being read.
    @ViewBuilder
    private func fillerHeat(_ m: ScreenroomSpeechMetrics) -> some View {
        let minutes = max(1, Int(ceil(Double(m.durationMs) / 60_000)))
        if minutes >= 3 {
            let times = m.fillers.flatMap(\.atMs)
            let perMinute = (0..<minutes).map { minute in
                times.filter { $0 >= minute * 60_000 && $0 < (minute + 1) * 60_000 }.count
            }
            let peak = max(perMinute.max() ?? 1, 1)
            VStack(alignment: .leading, spacing: 5) {
                Text("BY THE MINUTE")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(0.8).foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    ForEach(Array(perMinute.enumerated()), id: \.offset) { minute, count in
                        Button { review.seek(toMs: minute * 60_000, lead: 0) } label: {
                            VStack(spacing: 3) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Brand.fill.opacity(count == 0 ? 0.08
                                                             : 0.25 + 0.75 * Double(count) / Double(peak)))
                                    .frame(height: 28)
                                    .overlay(Text(count == 0 ? "" : "\(count)")
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Brand.text))
                                Text("\(minute)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: The notes, as marks on a time axis

    private var timeline: some View {
        let span = max(Double(review.metrics?.durationMs ?? 0),
                       Double((review.notes.map(\.atMs).max() ?? 0) + 1))
        return section("WHEN THE NOTES LANDED") {
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(nsColor: .separatorColor).opacity(0.35))
                            .frame(height: 4)
                        ForEach(review.notes) { note in
                            Capsule().fill(Brand.fill)
                                .frame(width: 3, height: 22)
                                .offset(x: geo.size.width * (Double(note.atMs) / span) - 1.5)
                                .help("\(note.offsetLabel)  \(note.text)")
                                .onTapGesture { review.seek(to: note) }
                        }
                    }
                    .frame(height: 22)
                }
                .frame(height: 22)
                HStack {
                    Text("0:00")
                    Spacer()
                    Text(Self.clock(Int(span / 1000)))
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var noteList: some View {
        section("EVERY NOTE", trailing: "click one to play it") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(review.notes.enumerated()), id: \.element.id) { index, note in
                    Button {
                        review.seek(to: note)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(note.offsetLabel)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(Brand.text)
                                .frame(width: 44, alignment: .leading)
                            Text(note.text)
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < review.notes.count - 1 {
                        Divider().opacity(0.5)
                    }
                }
            }
        }
    }

    // MARK: For the marker only

    private var consistency: some View {
        section("FOR YOU, NOT THE SPEAKER",
                trailing: "how this marking sat against the group") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(review.cohortFindings) { finding in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        // Shape and label, never colour alone - and never
                        // amber, which means "leaves your Mac" in this app.
                        Image(systemName: finding.weight == .check
                              ? "exclamationmark.circle.fill" : "equal.circle")
                            .font(.caption)
                            .foregroundStyle(finding.weight == .check
                                             ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(finding.headline).font(.callout.weight(.medium))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(finding.detail).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    /// Where every sentence above came from. Not a footnote: an analysis
    /// written by a model and one counted from timestamps are different kinds
    /// of claim, and the report has to say which it is holding.
    private var provenance: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text(provenanceLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    private var provenanceLine: String {
        var parts: [String] = ["Notes typed live during the presentation."]
        if let analysis = review.analysis {
            parts.append("The written sections came from \(analysis.engine), reading those notes and nothing else \u{2014} not the recording.")
        }
        if let metrics = review.metrics, metrics.wordCount > 0 {
            parts.append(metrics.verbatim
                ? "Speech figures counted from a verbatim transcript by \(metrics.engine)."
                : "\(metrics.engine) returns a cleaned-up transcript, so filler words and hedges were not counted.")
        }
        if let seen = review.presence, seen.sampleCount > 0 {
            parts.append("On-camera figures measured by Apple's Vision framework, \(seen.sampleCount) samples \(seen.everyMs / 1000) seconds apart, from head angle and wrist position \u{2014} not from gaze.")
        }
        parts.append("Everything counted ran on this Mac.")
        return parts.joined(separator: " ")
    }

    // MARK: Furniture

    @ViewBuilder
    private func section<Content: View>(_ title: String, trailing: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                eyebrow(title)
                Spacer(minLength: 0)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            content()
        }
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .tracking(1)
            .foregroundStyle(Brand.text)
    }

    static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", max(0, seconds) / 60, max(0, seconds) % 60)
    }

    static func duration(_ ms: Int) -> String {
        let s = max(0, ms / 1000)
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }
}
