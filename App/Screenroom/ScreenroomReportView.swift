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
//   - The headline readings are cards that say, in a sentence, where each
//     number sits against its comfortable range. They were dials, and the
//     dials were reported as unreadable: a ring does not say whether 137 is
//     fine, and the same three numbers were then drawn a second time as
//     bars further down. One card per reading, said once.
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
                    // The readings, then the map, then what to do about
                    // them, then the detail. Each reading says in words
                    // where it sits, so the top of the page can be read
                    // without decoding a single chart.
                    glance
                    if hasMap { map }
                    if let analysis = review.analysis { prose(analysis) }
                    if review.scoring.markedCount > 0 { rubric }
                    // Under three windows a line is two points, and the card above
                    // already says the one thing it could.
                    if let metrics = review.metrics, metrics.paceWindow.count >= 3 { pace(metrics) }
                    if let metrics = review.metrics, metrics.fillerCount > 0 { fillers(metrics) }
                    if let metrics = review.metrics, metrics.hedgeCount > 0 { hedges(metrics) }
                    if let metrics = review.metrics, metrics.runs.count >= Self.enoughSentences { sentenceShape(metrics) }
                    if let metrics = review.metrics, metrics.vocabulary > 0 { vocabulary(metrics) }
                    if let metrics = review.metrics, metrics.wordCount > 0 { airTime(metrics) }
                    if let seen = review.presence, seen.sampleCount > 0 { onCamera(seen) }
                    if let metrics = review.metrics, metrics.verbatim, !metrics.careful.isEmpty {
                        careful(metrics)
                    }
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

    // MARK: Pace — one series over time

    private func pace(_ metrics: ScreenroomSpeechMetrics) -> some View {
        section("PACE", trailing: "words per minute, in half-minute windows") {
            Chart {
                // The comfortable range as shading behind the line, so a
                // dip below it or a spike above it reads without the reader
                // holding a number in their head.
                RectangleMark(
                    xStart: .value("From", 0),
                    xEnd: .value("To", Double(metrics.durationMs) / 1000),
                    yStart: .value("Slow", ScreenroomSpeechMetrics.comfortablePace.lowerBound),
                    yEnd: .value("Fast", ScreenroomSpeechMetrics.comfortablePace.upperBound))
                    .foregroundStyle(Brand.fill.opacity(0.10))
                // Each window drawn at its middle, not its start: at its start
                // the line stopped half a window short of the end of the talk.
                ForEach(metrics.paceWindow, id: \.startMs) { window in
                    AreaMark(x: .value("At", Self.middle(of: window, in: metrics)),
                             y: .value("Words per minute", window.wordsPerMinute))
                        .foregroundStyle(Brand.fill.opacity(0.18))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("At", Self.middle(of: window, in: metrics)),
                             y: .value("Words per minute", window.wordsPerMinute))
                        .foregroundStyle(Brand.fill)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)
                }
                // The average as a baseline to read the shape against.
                RuleMark(y: .value("Average", metrics.wordsPerMinute))
                    .foregroundStyle(Brand.recessive)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("average \(Int(metrics.wordsPerMinute.rounded()))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
            }
            .chartXScale(domain: 0...max(1, Double(metrics.durationMs) / 1000))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    // Hairline, never dashed: dashing is noise.
                    AxisGridLine().foregroundStyle(Color(nsColor: .separatorColor).opacity(0.4))
                    AxisValueLabel {
                        if let seconds = value.as(Double.self) {
                            Text(Self.clock(Int(seconds)))
                                .font(.system(size: 11, design: .monospaced))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(Color(nsColor: .separatorColor).opacity(0.4))
                    AxisValueLabel {
                        if let wpm = value.as(Double.self) {
                            Text("\(Int(wpm))").font(.system(size: 11, design: .monospaced))
                        }
                    }
                }
            }
            .frame(height: 150)
        }
    }

    /// The middle of a half-minute window, in seconds, never past the end.
    static func middle(of window: ScreenroomSpeechMetrics.PaceWindow,
                       in metrics: ScreenroomSpeechMetrics) -> Double {
        let end = min(window.startMs + 30_000, metrics.durationMs)
        return Double(window.startMs + end) / 2000
    }

    // MARK: Fillers — magnitude, one hue for every bar

    private func fillers(_ metrics: ScreenroomSpeechMetrics) -> some View {
        // Past six, the tail is noise on a chart and belongs in a sentence.
        let shown = Array(metrics.fillers.prefix(6))
        let rest = metrics.fillers.dropFirst(6)
        return section("FILLER WORDS", trailing: "\(metrics.fillerCount) in total") {
            VStack(alignment: .leading, spacing: 10) {
                Chart(shown) { filler in
                    BarMark(x: .value("Times", filler.count),
                            y: .value("Word", filler.word))
                        // One series, one colour. Darkening the bigger bars
                        // would double-encode length as hue and tell the
                        // reader nothing the length has not already said.
                        .foregroundStyle(Brand.fill)
                        .cornerRadius(4)
                        .annotation(position: .trailing, alignment: .leading) {
                            Text("\(filler.count)")
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

                // Where they fell matters more than how many. Thirty-one
                // fillers spread evenly is a habit; thirty-one in the last
                // two minutes is nerves running out of script.
                strip("every one of them, in order \u{00B7} click to play",
                      times: metrics.fillers.flatMap(\.atMs))

                fillerHeat(metrics)

                if let worst = metrics.fillers.first {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\u{201C}\(worst.word)\u{201D}")
                            .font(.callout.weight(.medium))
                        Spacer(minLength: 0)
                        ForEach(worst.atMs.prefix(8), id: \.self) { at in timeChip(at) }
                        if worst.atMs.count > 8 {
                            Text("+\(worst.atMs.count - 8)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }


    // MARK: Hedges, counted the same way fillers are

    private func hedges(_ m: ScreenroomSpeechMetrics) -> some View {
        section("HEDGES AND SOFTENERS",
                trailing: "\(m.hedgeCount) in total \u{00B7} they soften the claim, not change it") {
            VStack(alignment: .leading, spacing: 12) {
                wordBars(m.hedges, limit: 6)
                strip("where they landed", times: m.hedges.flatMap(\.atMs))
            }
        }
    }

    // MARK: Words worth a second look

    private func careful(_ m: ScreenroomSpeechMetrics) -> some View {
        section("WORTH A SECOND LOOK", trailing: "not errors, not scored") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(m.careful) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\u{201C}\(item.word)\u{201D}").font(.callout.weight(.medium))
                        Text(item.count == 1 ? "once" : "\(item.count) times")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        ForEach(item.atMs.prefix(6), id: \.self) { at in
                            timeChip(at)
                        }
                    }
                }
            }
        }
    }

    // MARK: Sentence shape

    private func sentenceShape(_ m: ScreenroomSpeechMetrics) -> some View {
        section("SENTENCE SHAPE", trailing: "measured between breaths, not from punctuation") {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    tile("\(Int(m.wordsPerRun.rounded()))", "Words per sentence")
                    tile("\(m.runs.count)", "Sentences")
                    tile(String(format: "%.0fs", Double(m.longestRunMs) / 1000),
                         "Longest without a breath",
                         note: "from \(Self.clock(m.longestRunStartMs / 1000))")
                }
                if m.starters.count >= 2, m.runs.count >= 6 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("HOW THEY OPENED")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .tracking(0.8).foregroundStyle(.secondary)
                        wordBars(m.starters, limit: 6)
                    }
                }
            }
        }
    }

    // MARK: Vocabulary

    private func vocabulary(_ m: ScreenroomSpeechMetrics) -> some View {
        section("VOCABULARY", trailing: "variety measured over fifty-word windows") {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    tile("\(Int((m.vocabulary * 100).rounded()))%", "Variety",
                         note: "different words per fifty said")
                    tile("\(m.uniqueWords)", "Different words",
                         note: "of \(m.wordCount) spoken")
                }
                if !m.repeated.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("LEANED ON MOST \u{00B7} COMMON WORDS EXCLUDED")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .tracking(0.8).foregroundStyle(.secondary)
                        wordBars(m.repeated, limit: 8)
                    }
                }
            }
        }
    }

    // MARK: Air time

    private func airTime(_ m: ScreenroomSpeechMetrics) -> some View {
        section("AIR TIME", trailing: "talking against silence") {
            VStack(alignment: .leading, spacing: 12) {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 3).fill(Brand.fill)
                            .frame(width: max(2, geo.size.width * m.talkRatio))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(nsColor: .separatorColor).opacity(0.3))
                    }
                }
                .frame(height: 16)
                HStack {
                    Text("\(Int((m.talkRatio * 100).rounded()))% talking")
                        .foregroundStyle(Brand.text)
                    Spacer()
                    Text("\(Int(((1 - m.talkRatio) * 100).rounded()))% silence")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))

                if !m.pauses.isEmpty {
                    Text("LONGEST PAUSES \u{00B7} SILENCE IS WHERE A ROOM CATCHES UP")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(0.8).foregroundStyle(.secondary)
                        .padding(.top, 4)
                    HStack(spacing: 6) {
                        ForEach(m.pauses.prefix(8)) { pause in
                            Button { review.seek(toMs: pause.startMs) } label: {
                                VStack(spacing: 1) {
                                    Text(String(format: "%.1fs", Double(pause.lengthMs) / 1000))
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    Text(Self.clock(pause.startMs / 1000))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 5).padding(.horizontal, 8)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(Color(nsColor: .controlBackgroundColor)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: What the camera saw

    /// The honest version of the "eye contact" figure these tools report.
    ///
    /// Vision gives the angle of the head, not the direction of the eyes, so
    /// the heading says FACING THE ROOM and the footnote says why. A number
    /// labelled eye contact that cannot see eyes is the kind of thing a
    /// student repeats in an interview.
    private func onCamera(_ seen: ScreenroomPresence) -> some View {
        section("ON CAMERA",
                trailing: "head angle, sampled every \(seen.everyMs / 1000) seconds \u{00B7} not eye contact") {
            VStack(alignment: .leading, spacing: 16) {
                // Facing the room is a card at the top of the page; saying
                // it again here as a tile was the same number twice.
                HStack(spacing: 12) {
                    tile("\(Int((seen.onCameraRatio * 100).rounded()))%", "In shot")
                    if let ratio = seen.gestureRatio, let rate = seen.gesturesPerMinute {
                        tile("\(Int((ratio * 100).rounded()))%", "Hands up",
                             note: String(format: "%.1f movements a minute", rate))
                    }
                }

                // Said out loud rather than shown as a zero. A head-and-
                // shoulders webcam shot never has a wrist in it, and "0%
                // hands up" reads as a verdict on a presenter who did
                // nothing wrong except sit close to the camera.
                if !seen.sawBody {
                    Text("No gesture figures: the framing is too tight to find a body, so the hands were never in shot. Record from further back.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // The same strip is the Facing row of the map when the map is
                // drawn, so it is only shown here when the map is not.
                if !hasMap {
                VStack(alignment: .leading, spacing: 5) {
                    eyebrow("WHERE THEY WERE LOOKING")
                    presenceStrip(seen)
                    HStack(spacing: 14) {
                        key(Brand.fill, "facing the room")
                        key(Color(nsColor: .labelColor).opacity(0.6), "turned away")
                        key(Color(nsColor: .separatorColor).opacity(0.5), "no face in shot")
                        Spacer()
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                }

                if let away = seen.longestAway {
                    Button { review.seek(toMs: away.startMs) } label: {
                        Text("Longest stretch turned away or out of shot: \(String(format: "%.0f", Double(away.lengthMs) / 1000))s from \(Self.clock(away.startMs / 1000)).")
                            .font(.caption).foregroundStyle(.secondary)
                            .underline()
                    }
                    .buttonStyle(.plain)
                }

                if seen.sawBody, seen.samples.contains(where: { $0.motion > 0 }) {
                    VStack(alignment: .leading, spacing: 5) {
                        eyebrow("HAND MOVEMENT")
                        Chart(seen.samples) { sample in
                            AreaMark(x: .value("At", Double(sample.atMs) / 1000),
                                     y: .value("Movement", sample.motion))
                                .foregroundStyle(Brand.fill.opacity(0.3))
                                .interpolationMethod(.monotone)
                        }
                        .chartYAxis(.hidden)
                        .chartXAxis {
                            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                                AxisGridLine().foregroundStyle(Color(nsColor: .separatorColor).opacity(0.4))
                                AxisValueLabel {
                                    if let s = value.as(Double.self) {
                                        Text(Self.clock(Int(s))).font(.system(size: 11, design: .monospaced))
                                    }
                                }
                            }
                        }
                        .frame(height: 70)
                    }
                }

                Text("Head angle and wrist position, measured on this Mac by Vision. Not eye contact \u{2014} nothing here can see where the eyes pointed. Movement only \u{2014} whether a gesture helped is a judgement.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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

    /// The stills, evenly sampled to fit the column. Already on disk and,
    /// until now, only ever read by the agent.
    private var filmstrip: some View {
        // Six at 16:9 fills the column at roughly the camera's own shape.
        // Nine squeezed into 52pt cropped every still to a forehead.
        let wanted = 6
        let all = review.frames
        let step = max(1, all.count / wanted)
        let shown = stride(from: 0, to: all.count, by: step).prefix(wanted).map { all[$0] }
        return HStack(spacing: 2) {
            ForEach(shown, id: \.self) { url in
                Button { review.seek(toMs: Self.stamp(of: url), lead: 0) } label: {
                    Group {
                        if let image = NSImage(contentsOf: url) {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color(nsColor: .separatorColor).opacity(0.3)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
    }

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

    // MARK: The readings, said in words

    /// Below this many breaths, "words per sentence" is the length of the
    /// whole recording: a 42-second clip read in one breath reported a
    /// 96-word sentence and "1 stretches of speech".
    static let enoughSentences = 3

    /// One reading: the number, what it is measured in, and where it sits
    /// against the range a room follows comfortably - said in words, not
    /// left for the reader to work out from an arc.
    fileprivate struct Reading: Identifiable {
        enum Side { case below, inside, above }
        let label: String
        let value: String
        let unit: String
        let side: Side?
        let verdict: String
        let range: String?
        /// 0...1 positions on the meter. Nil draws no meter.
        let meter: (value: Double, low: Double, high: Double)?
        var id: String { label }
    }

    /// Four or five cards, two to a row.
    ///
    /// These replace four dials and a second section that repeated the same
    /// three numbers as bars. The dials were reported as unreadable: 8pt
    /// captions colliding with the ring, and nothing on them saying whether
    /// 137 was fine. Each card now says it in a sentence; the meter under it
    /// is the evidence, not the message.
    ///
    /// The wording describes where the reading sits against the range and
    /// stops there. "Faster than the comfortable range" is a measurement;
    /// "too fast" would be a judgement the teacher gets to make.
    private var glance: some View {
        let readings = self.readings
        return Group {
            if !readings.isEmpty {
                // Two to a row, and an odd one out takes the whole row rather
                // than leaving a card-shaped hole beside it.
                let rows = stride(from: 0, to: readings.count, by: 2).map {
                    Array(readings[$0..<min($0 + 2, readings.count)])
                }
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    ForEach(rows, id: \.first!.id) { row in
                        GridRow(alignment: .top) {
                            ForEach(row) { reading in
                                card(reading).gridCellColumns(row.count == 1 ? 2 : 1)
                            }
                        }
                    }
                }
            }
        }
    }

    private var readings: [Reading] {
        var out: [Reading] = []
        if let m = review.metrics, m.wordCount > 0 {
            out.append(reading("Pace", value: m.wordsPerMinute, shown: "\(Int(m.wordsPerMinute.rounded()))",
                               unit: "words a minute",
                               band: ScreenroomSpeechMetrics.comfortablePace, scale: 0...260,
                               below: "Slower than the comfortable range",
                               inside: "In the comfortable range",
                               above: "Faster than the comfortable range",
                               range: "comfortable 115\u{2013}180"))
            if m.verbatim {
                out.append(reading("Filler words", value: m.fillersPerMinute,
                                   shown: String(format: "%.1f", m.fillersPerMinute),
                                   unit: "a minute \u{00B7} \(m.fillerCount) in total",
                                   band: 0...2, scale: 0...12,
                                   below: "Fewer than usual",
                                   inside: "Within the usual range",
                                   above: "More than the usual range",
                                   range: "usual 0\u{2013}2"))
            } else {
                out.append(Reading(label: "Filler words", value: "\u{2014}", unit: "not counted",
                                   side: nil,
                                   verdict: "This transcript was tidied, so fillers could not be counted. Transcribe with whisper to count them.",
                                   range: nil, meter: nil))
            }
            if m.runs.count >= Self.enoughSentences, m.wordsPerRun > 0 {
                out.append(reading("Sentence length", value: m.wordsPerRun,
                                   shown: "\(Int(m.wordsPerRun.rounded()))",
                                   unit: "words between breaths",
                                   band: 8...20, scale: 0...45,
                                   below: "Shorter than usual",
                                   inside: "In the usual range",
                                   above: "Longer than usual",
                                   range: "usual 8\u{2013}20"))
            }
        }
        if let seen = review.presence, seen.sampleCount > 0 {
            out.append(reading("Facing the room", value: seen.facingRatio,
                               shown: "\(Int((seen.facingRatio * 100).rounded()))%",
                               unit: "of the time a face was in shot",
                               band: 0.6...1, scale: 0...1,
                               // Under 60% is not the same claim as under half.
                               below: seen.facingRatio < 0.5 ? "Turned away more often than not"
                                   : "Facing the room less often than usual",
                               inside: "Facing the room most of the time",
                               above: "Facing the room most of the time",
                               range: "aim for 60%+"))
        }
        if review.scoring.markedCount > 0, review.scoring.availableOnMarkedLines > 0 {
            // Out of what was actually marked, not out of the whole rubric:
            // a half-filled rubric reports the half it has.
            let outOf = Double(review.scoring.availableOnMarkedLines)
            let share = Double(review.scoring.awarded) / outOf
            let lines = review.scoring.rubric.criteria.count
            out.append(Reading(
                label: "Marks", value: review.scoring.totalLabel,
                unit: review.scoring.isComplete ? "overall"
                    : "\(review.scoring.markedCount) of \(lines) lines marked",
                side: nil,
                verdict: "\(Int((share * 100).rounded()))% of the marks available",
                range: nil,
                meter: (share, 0, 0)))
        }
        return out
    }

    private func reading(_ label: String, value: Double, shown: String, unit: String,
                         band: ClosedRange<Double>, scale: ClosedRange<Double>,
                         below: String, inside: String, above: String,
                         range: String) -> Reading {
        let width = max(0.001, scale.upperBound - scale.lowerBound)
        func at(_ x: Double) -> Double { min(1, max(0, (x - scale.lowerBound) / width)) }
        let side: Reading.Side = value < band.lowerBound ? .below
            : value > band.upperBound ? .above : .inside
        let verdict = side == .below ? below : side == .above ? above : inside
        return Reading(label: label, value: shown, unit: unit, side: side, verdict: verdict,
                       range: range,
                       meter: (at(value), at(band.lowerBound), at(band.upperBound)))
    }

    private func card(_ r: Reading) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(r.label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(r.value)
                    .font(.system(size: 32, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(r.unit)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let meter = r.meter { cardMeter(meter, inside: r.side != .below && r.side != .above) }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // Shape carries the side, never colour alone.
                if let side = r.side {
                    Image(systemName: side == .inside ? "checkmark.circle.fill"
                          : side == .above ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                        .foregroundStyle(side == .inside ? AnyShapeStyle(Brand.text) : AnyShapeStyle(.primary))
                }
                Text(r.verdict)
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let range = r.range {
                    Text(range)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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

    /// The range shaded, the reading as a marker. A band of zero width is a
    /// plain fill meter - the marks, which have no "comfortable" range.
    private func cardMeter(_ m: (value: Double, low: Double, high: Double), inside: Bool) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: .separatorColor).opacity(0.5))
                    .frame(height: 6)
                if m.high > m.low {
                    Rectangle().fill(Brand.fill.opacity(0.35))
                        .frame(width: w * (m.high - m.low), height: 6)
                        .offset(x: w * m.low)
                    Capsule()
                        .fill(inside ? AnyShapeStyle(Brand.fill) : AnyShapeStyle(Color(nsColor: .labelColor)))
                        .frame(width: 4, height: 16)
                        .offset(x: min(w - 4, max(0, w * m.value - 2)))
                } else {
                    Capsule().fill(Brand.fill)
                        .frame(width: max(6, w * m.value), height: 6)
                }
            }
            .frame(height: 16)
        }
        .frame(height: 16)
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
