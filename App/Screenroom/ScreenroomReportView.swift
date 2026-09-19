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
//   - The four headline numbers are stat tiles. A one-bar bar chart is the
//     classic way to turn a number into a worse number.
//   - A rubric line is a ratio against a limit, so it is a meter - a filled
//     track - rather than a bar on a shared axis. Five meters at five
//     different maxima on one axis would compare things that are not
//     comparable.
//   - The notes are marks on a time axis, not a series. They have no
//     magnitude; only position.
//   - Pace, filler rate and sentence length are read against a band rather
//     than against zero, so each is a marker on a track with the comfortable
//     range shaded. A bar chart of "your pace" would ask the reader to
//     compare one bar against nothing.
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
                    headline
                    if let analysis = review.analysis { prose(analysis) }
                    if review.scoring.markedCount > 0 { rubric }
                    if let metrics = review.metrics, metrics.wordCount > 0 { bands(metrics) }
                    if let metrics = review.metrics, !metrics.paceWindow.isEmpty { pace(metrics) }
                    if let metrics = review.metrics, metrics.fillerCount > 0 { fillers(metrics) }
                    if let metrics = review.metrics, metrics.hedgeCount > 0 { hedges(metrics) }
                    if let metrics = review.metrics, !metrics.runs.isEmpty { sentenceShape(metrics) }
                    if let metrics = review.metrics, metrics.vocabulary > 0 { vocabulary(metrics) }
                    if let metrics = review.metrics, metrics.wordCount > 0 { airTime(metrics) }
                    if let seen = review.presence, seen.sampleCount > 0 { onCamera(seen) }
                    if let metrics = review.metrics, metrics.verbatim, !metrics.careful.isEmpty {
                        careful(metrics)
                    }
                    if !review.words.isEmpty { transcript }
                    if !review.notes.isEmpty { timeline }
                    if !review.notes.isEmpty { noteList }
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
            Text("Pick one in Past Presentations.")
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

    // MARK: The four numbers

    /// A KPI row, not a grouped bar chart. Four headline numbers whose only
    /// relationship is that they describe the same twenty minutes.
    private var headline: some View {
        HStack(spacing: 12) {
            if review.scoring.markedCount > 0 {
                tile(review.scoring.totalLabel, "MARKS",
                     note: review.scoring.isComplete ? nil : "\(review.scoring.markedCount) of \(review.scoring.rubric.criteria.count) lines")
            }
            if let m = review.metrics, m.wordCount > 0 {
                tile("\(Int(m.wordsPerMinute.rounded()))", "WORDS / MIN")
                if m.verbatim {
                    tile(String(format: "%.1f", m.fillersPerMinute), "FILLERS / MIN",
                         note: "\(m.fillerCount) in total")
                } else {
                    tile("\u{2014}", "FILLERS / MIN", note: "not counted")
                }
            }
            tile("\(review.notes.count)", review.notes.count == 1 ? "NOTE" : "NOTES")
        }
    }

    private func tile(_ value: String, _ label: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            VStack(alignment: .leading, spacing: 2) {
                eyebrow(label)
                if let note {
                    Text(note).font(.caption2).foregroundStyle(.tertiary)
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

    private func prose(_ analysis: ScreenroomAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if !analysis.summary.isEmpty {
                Text(analysis.summary)
                    .font(.system(size: 17))
                    .lineSpacing(4)
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

    @ViewBuilder
    private func bulletColumn(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                eyebrow(title)
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
            VStack(spacing: 14) {
                ForEach(review.scoring.rubric.criteria) { criterion in
                    meter(criterion)
                }
            }
        }
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
                ForEach(metrics.paceWindow, id: \.startMs) { window in
                    AreaMark(x: .value("At", Double(window.startMs) / 1000),
                             y: .value("Words per minute", window.wordsPerMinute))
                        .foregroundStyle(Brand.fill.opacity(0.18))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("At", Double(window.startMs) / 1000),
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
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    // Hairline, never dashed: dashing is noise.
                    AxisGridLine().foregroundStyle(Color(nsColor: .separatorColor).opacity(0.4))
                    AxisValueLabel {
                        if let seconds = value.as(Double.self) {
                            Text(Self.clock(Int(seconds)))
                                .font(.system(size: 9, design: .monospaced))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(Color(nsColor: .separatorColor).opacity(0.4))
                    AxisValueLabel {
                        if let wpm = value.as(Double.self) {
                            Text("\(Int(wpm))").font(.system(size: 9, design: .monospaced))
                        }
                    }
                }
            }
            .frame(height: 150)
        }
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
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
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
                        .font(.caption).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Where they fell matters more than how many. Thirty-one
                // fillers spread evenly is a habit; thirty-one in the last
                // two minutes is nerves running out of script.
                strip("every one of them, in order \u{00B7} click to play",
                      times: metrics.fillers.flatMap(\.atMs))

                if let worst = metrics.fillers.first {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\u{201C}\(worst.word)\u{201D}")
                            .font(.callout.weight(.medium))
                        Spacer(minLength: 0)
                        ForEach(worst.atMs.prefix(8), id: \.self) { at in timeChip(at) }
                        if worst.atMs.count > 8 {
                            Text("+\(worst.atMs.count - 8)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }


    // MARK: Read against a band, not against zero

    /// Three numbers that mean nothing on their own.
    ///
    /// 142 words a minute is neither good nor bad until you know what a room
    /// follows comfortably, so each of these is a marker on a track with the
    /// comfortable range shaded behind it. The shading is the finding; the
    /// number is the label. Nothing here says "too fast" - the band is drawn
    /// and the reader decides, because what counts as too fast depends on the
    /// subject, the room, and how much English the audience has.
    private func bands(_ m: ScreenroomSpeechMetrics) -> some View {
        section("HOW IT LANDED", trailing: "shaded range is where a room follows comfortably") {
            VStack(spacing: 16) {
                bandMeter("Pace", value: m.wordsPerMinute, unit: "words a minute",
                          band: ScreenroomSpeechMetrics.comfortablePace, scale: 0...260)
                if m.verbatim {
                    bandMeter("Fillers", value: m.fillersPerMinute, unit: "a minute",
                              band: 0...2, scale: 0...12,
                              note: "\(m.fillerCount) in total")
                }
                if m.wordsPerRun > 0 {
                    bandMeter("Sentence length", value: m.wordsPerRun, unit: "words between breaths",
                              band: 8...20, scale: 0...45,
                              note: "\(m.runs.count) stretches of speech")
                }
            }
        }
    }

    private func bandMeter(_ label: String, value: Double, unit: String,
                           band: ClosedRange<Double>, scale: ClosedRange<Double>,
                           note: String? = nil) -> some View {
        let width = max(0.001, scale.upperBound - scale.lowerBound)
        func fraction(_ x: Double) -> Double {
            min(1, max(0, (x - scale.lowerBound) / width))
        }
        let inside = band.contains(value)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label).font(.callout.weight(.medium))
                Text(unit).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if let note {
                    Text(note).font(.caption2).foregroundStyle(.tertiary)
                }
                Text(value < 10 ? String(format: "%.1f", value) : "\(Int(value.rounded()))")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(nsColor: .separatorColor).opacity(0.25))
                    // The comfortable range. Lime at low opacity: it is the
                    // context, not the reading.
                    Capsule().fill(Brand.fill.opacity(0.22))
                        .frame(width: geo.size.width * (fraction(band.upperBound) - fraction(band.lowerBound)))
                        .offset(x: geo.size.width * fraction(band.lowerBound))
                    // This speaker. A solid marker, and hollow when it sits
                    // outside the band - shape, never colour alone.
                    Capsule()
                        .fill(inside ? AnyShapeStyle(Brand.fill) : AnyShapeStyle(Color(nsColor: .labelColor)))
                        .frame(width: 4, height: 18)
                        .offset(x: geo.size.width * fraction(value) - 2)
                }
                .frame(height: 18)
            }
            .frame(height: 18)
            HStack {
                Text("\(Int(scale.lowerBound))")
                Spacer()
                Text("\(Int(band.lowerBound))\u{2013}\(Int(band.upperBound))")
                Spacer()
                Text("\(Int(scale.upperBound))")
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
    }

    // MARK: Hedges, counted the same way fillers are

    private func hedges(_ m: ScreenroomSpeechMetrics) -> some View {
        section("HEDGES AND SOFTENERS", trailing: "\(m.hedgeCount) in total") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Words that make a true sentence sound less certain. Removing them changes the confidence, not the claim.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                wordBars(m.hedges, limit: 6)
                strip("where they landed", times: m.hedges.flatMap(\.atMs))
            }
        }
    }

    // MARK: Words worth a second look

    private func careful(_ m: ScreenroomSpeechMetrics) -> some View {
        section("WORTH A SECOND LOOK") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Not errors, and not a score. These are words that land differently in front of a room than they do in a rehearsal, and the person who was there decides whether they mattered.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(m.careful) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\u{201C}\(item.word)\u{201D}").font(.callout.weight(.medium))
                        Text(item.count == 1 ? "once" : "\(item.count) times")
                            .font(.caption).foregroundStyle(.tertiary)
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
                    tile("\(Int(m.wordsPerRun.rounded()))", "WORDS PER SENTENCE")
                    tile("\(m.runs.count)", "SENTENCES")
                    tile(String(format: "%.0fs", Double(m.longestRunMs) / 1000),
                         "LONGEST WITHOUT A BREATH",
                         note: "from \(Self.clock(m.longestRunStartMs / 1000))")
                }
                if m.starters.count >= 2, m.runs.count >= 6 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("How those sentences opened. Nobody hears themselves do this.")
                            .font(.caption).foregroundStyle(.secondary)
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
                    tile("\(Int((m.vocabulary * 100).rounded()))%", "VARIETY",
                         note: "different words per fifty said")
                    tile("\(m.uniqueWords)", "DIFFERENT WORDS",
                         note: "of \(m.wordCount) spoken")
                }
                if !m.repeated.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Leaned on most. Common words are excluded, so these are the ones carrying the talk \u{2014} sometimes because it is the subject, sometimes because it is a rut.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
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
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))

                if !m.pauses.isEmpty {
                    Text("\(m.pauses.count) \(m.pauses.count == 1 ? "pause" : "pauses") over two seconds. Silence is not a fault \u{2014} it is where a room catches up.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        ForEach(m.pauses.prefix(8)) { pause in
                            Button { review.seek(toMs: pause.startMs) } label: {
                                VStack(spacing: 1) {
                                    Text(String(format: "%.1fs", Double(pause.lengthMs) / 1000))
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    Text(Self.clock(pause.startMs / 1000))
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.tertiary)
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
        section("ON CAMERA", trailing: "sampled every \(seen.everyMs / 1000) seconds") {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    tile("\(Int((seen.facingRatio * 100).rounded()))%", "FACING THE ROOM",
                         note: "of frames with a face")
                    tile("\(Int((seen.onCameraRatio * 100).rounded()))%", "IN SHOT")
                    if let ratio = seen.gestureRatio, let rate = seen.gesturesPerMinute {
                        tile("\(Int((ratio * 100).rounded()))%", "HANDS UP",
                             note: String(format: "%.1f movements a minute", rate))
                    }
                }

                // Said out loud rather than shown as a zero. A head-and-
                // shoulders webcam shot never has a wrist in it, and "0%
                // hands up" reads as a verdict on a presenter who did
                // nothing wrong except sit close to the camera.
                if !seen.sawBody {
                    Text("Nothing here about gesture: the framing is too tight to find a body, so the hands were never in shot. Record from further back to measure it.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 5) {
                    eyebrow("WHERE THEY WERE LOOKING")
                    presenceStrip(seen)
                    HStack(spacing: 14) {
                        key(Brand.fill, "facing the room")
                        key(Color(nsColor: .labelColor).opacity(0.35), "turned away")
                        key(Color(nsColor: .separatorColor).opacity(0.4), "no face in shot")
                        Spacer()
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
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
                                        Text(Self.clock(Int(s))).font(.system(size: 9, design: .monospaced))
                                    }
                                }
                            }
                        }
                        .frame(height: 70)
                        Text("How far the wrists moved between samples. Movement only \u{2014} whether a gesture helped is a judgement, and it belongs in the notes.")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text("Measured on this Mac by Apple's Vision framework, from the angle of the head. It is not eye contact: nothing here can tell where the eyes were pointed.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func key(_ colour: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(colour).frame(width: 10, height: 6)
            Text(label)
        }
    }

    /// One tick per sample, drawn in a Canvas rather than as six hundred
    /// Rectangles. Clicking anywhere on it moves the recording there.
    private func presenceStrip(_ seen: ScreenroomPresence) -> some View {
        let span = max(1.0, Double((seen.samples.last?.atMs ?? 0) + seen.everyMs))
        return GeometryReader { geo in
            Canvas { context, size in
                let width = max(1, size.width / CGFloat(max(1, seen.samples.count)))
                for sample in seen.samples {
                    let x = size.width * CGFloat(Double(sample.atMs) / span)
                    let colour: Color = sample.facing
                        ? Brand.fill
                        : (sample.face ? Color(nsColor: .labelColor).opacity(0.35)
                                       : Color(nsColor: .separatorColor).opacity(0.4))
                    context.fill(Path(CGRect(x: x, y: 0, width: width + 0.5, height: size.height)),
                                 with: .color(colour))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .gesture(SpatialTapGesture().onEnded { value in
                review.seek(toMs: Int(span * Double(value.location.x / max(1, geo.size.width))))
            })
        }
        .frame(height: 20)
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
                    Text("This transcript came from a recogniser that tidies as it goes, so the crutch words are not in it to mark. Transcribe with whisper for the verbatim version.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(runs.isEmpty ? [ScreenroomSpeechMetrics.Run(startMs: review.words.first?.atMs ?? 0, endMs: review.words.last?.endMs ?? 0, words: review.words.count, opener: "")] : runs) { run in
                    Button { review.seek(toMs: run.startMs, lead: 500) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(Self.clock(run.startMs / 1000))
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
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
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
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
                    .font(.caption).foregroundStyle(.tertiary)
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
                Text(label).font(.caption2).foregroundStyle(.tertiary)
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
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Brand.text)
                .padding(.vertical, 2).padding(.horizontal, 5)
                .background(RoundedRectangle(cornerRadius: 4).fill(Brand.fill.opacity(0.15)))
        }
        .buttonStyle(.plain)
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
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
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
                .foregroundStyle(.tertiary)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                eyebrow(title)
                Spacer()
                if let trailing {
                    Text(trailing).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            content()
        }
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(0.8)
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
