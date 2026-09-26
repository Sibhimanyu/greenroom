//
//  ScreenroomExportMenu.swift
//  Greenroom
//
//  The one control that gets everything out. The mechanics are in
//  ScreenroomExport, which is kept free of the rest of the app so the PDF
//  pagination can be exercised without a window.
//
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The one control that gets everything out.
struct ScreenroomExportMenu: View {
    @ObservedObject var review: ScreenroomReviewController
    @State private var working = false

    var body: some View {
        Menu {
            Section("This report") {
                Button("Save as PDF\u{2026}") { savePDF() }
                Button("Save as Markdown\u{2026}") { saveMarkdown(.speaker) }
                Button("Save my copy, with the consistency check\u{2026}") { saveMarkdown(.evaluator) }
            }
            Section("The recording") {
                Button("Video with the notes on it\u{2026}") { saveVideo() }
                    .disabled(review.selected?.hasRecording != true)
                Button("Subtitles\u{2026}") { saveSubtitles() }
                    .disabled(review.selected?.hasRecording != true)
            }
            Divider()
            Button("Show the folder in Finder") {
                guard let folder = review.selected?.folder else { return }
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            }
        } label: {
            if working {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Working\u{2026}")
                }
            } else {
                Label("Export", systemImage: "square.and.arrow.up")
            }
        }
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .fixedSize()
        .disabled(review.selected == nil || working)
    }

    private var base: String {
        ScreenroomExport.baseName(presenter: review.selected?.presenter ?? "",
                                  date: review.selected?.presentedAt ?? Date())
    }

    private func savePDF() {
        guard let data = ScreenroomExport.pdf(of: ScreenroomReportView(paged: true),
                                              width: 860) else {
            review.report("The PDF could not be rendered.")
            return
        }
        if let url = ScreenroomExport.save(data, suggested: "\(base).pdf", type: .pdf,
                                           in: review.selected?.folder) {
            review.report("Saved \(url.lastPathComponent).")
        }
    }

    private func saveMarkdown(_ audience: ScreenroomReport.Audience) {
        guard let markdown = review.reportMarkdown(for: audience) else { return }
        let name = audience == .speaker ? "\(base).md" : "\(base) - marker copy.md"
        if let url = ScreenroomExport.save(Data(markdown.utf8), suggested: name,
                                           type: .plainText, in: review.selected?.folder) {
            review.report("Saved \(url.lastPathComponent).")
        }
    }

    private func saveVideo() {
        guard let folder = review.selected?.folder else { return }
        let existing = folder.appendingPathComponent(ScreenroomVideoExport.annotatedFileName)
        working = true
        Task {
            // Rendered on demand rather than assumed: the notes may have
            // changed since the last export, and a stale video with the wrong
            // sentences on it is worse than a wait.
            await review.exportAnnotatedVideo()
            working = false
            guard FileManager.default.fileExists(atPath: existing.path) else { return }
            if let url = ScreenroomExport.copy(existing, suggested: "\(base).mp4", type: .mpeg4Movie) {
                review.report("Saved \(url.lastPathComponent).")
            }
        }
    }

    private func saveSubtitles() {
        guard let folder = review.selected?.folder else { return }
        working = true
        Task {
            await review.exportSubtitles()
            working = false
            let existing = folder.appendingPathComponent(ScreenroomVideoExport.subtitleFileName)
            guard FileManager.default.fileExists(atPath: existing.path) else { return }
            if let url = ScreenroomExport.copy(existing, suggested: "\(base).srt", type: .plainText) {
                review.report("Saved \(url.lastPathComponent).")
            }
        }
    }
}
