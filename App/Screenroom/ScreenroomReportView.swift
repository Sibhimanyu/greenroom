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
                    if let metrics = review.metrics, !metrics.paceWindow.isEmpty { pace(metrics) }
                    if let metrics = review.metrics, metrics.fillerCount > 0 { fillers(metrics) }
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
                : "\(metrics.engine) returns a cleaned-up transcript, so filler words were not counted.")
        }
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
