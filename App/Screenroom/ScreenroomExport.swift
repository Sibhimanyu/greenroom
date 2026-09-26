//
//  ScreenroomExport.swift
//  Greenroom
//
//  Getting the report out of the app.
//
//  The first version wrote report.md into the presentation's folder and put a
//  sentence in the status line saying so. That is the correct thing to do with
//  a file the app owns and the wrong thing to do with a document somebody is
//  about to send a student: it ends up somewhere they did not choose, under a
//  name they did not pick, and the only way to find it is a Finder button.
//
//  So every export asks where it goes, defaulting to the presentation's folder
//  and to a name built from the student's own. The folder copy still happens
//  for report.md, because the folder is the contract other things read.
//
//  PDF is rendered from the dashboard itself through ImageRenderer rather than
//  laid out a second time. A second layout is a second thing to keep in step,
//  and the whole point of the PDF is that it is what is on screen.
//
import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ScreenroomExport {

    /// US Letter at 72dpi. Not A4: the one certain thing about the paper is
    /// that nobody is going to print it, and Letter is what Preview, Mail and
    /// every American LMS assume.
    static let pageSize = CGSize(width: 612, height: 792)

    /// Renders a SwiftUI view to a multi-page PDF.
    ///
    /// ImageRenderer gives one tall image for the whole view; this slices it
    /// into pages by translating the CTM a page-height at a time, which is the
    /// standard trick and the only one that does not require the view to know
    /// about pagination. The cost is that a page break can land through the
    /// middle of a line of text, which is the accepted price for the PDF being
    /// exactly what the window shows.
    @MainActor
    static func pdf<V: View>(of view: V, width: CGFloat) -> Data? {
        let renderer = ImageRenderer(content:
            view.frame(width: width).environment(\.colorScheme, .light))
        renderer.scale = 2

        var box = CGRect(origin: .zero, size: pageSize)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }

        var rendered = false
        renderer.render { size, draw in
            let scale = pageSize.width / size.width
            let pageContentHeight = pageSize.height / scale
            let pages = max(1, Int(ceil(size.height / pageContentHeight)))

            for page in 0..<pages {
                context.beginPDFPage(nil)
                context.saveGState()
                // No flip: ImageRenderer already draws the right way up in
                // Core Graphics' bottom-left space, with the top of the view
                // at size.height. Flipping it again printed every page upside
                // down and in reverse order. Page 0 is the top slice, so each
                // page shifts the view down until its slice sits on the sheet.
                context.scaleBy(x: scale, y: scale)
                context.translateBy(x: 0, y: -(size.height - CGFloat(page + 1) * pageContentHeight))
                draw(context)
                context.restoreGState()
                context.endPDFPage()
            }
            rendered = true
        }
        context.closePDF()
        return rendered ? data as Data : nil
    }

    /// Asks where a file goes, then writes it.
    ///
    /// Returns the URL so the caller can say what it did. A cancelled panel
    /// returns nil and is not a failure - it is the user changing their mind,
    /// and should not produce an error message.
    @discardableResult
    static func save(_ data: Data, suggested name: String, type: UTType,
                     in folder: URL?) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        if let folder { panel.directoryURL = folder }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }

    /// Copies a file the app already produced - the annotated video, the
    /// subtitles - to somewhere the teacher picks.
    @discardableResult
    static func copy(_ source: URL, suggested name: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try? FileManager.default.removeItem(at: url)
        guard (try? FileManager.default.copyItem(at: source, to: url)) != nil else { return nil }
        return url
    }

    /// `Priya Raman - 18 Sep 2026` - a file name a human would have typed.
    ///
    /// Sanitised here rather than through GreenroomScene, so this file has no
    /// dependency on the rest of the app and can be exercised on its own. The
    /// rules are the same two characters: `/` and `:` are what the filesystem
    /// and Finder disagree about.
    static func baseName(presenter: String, date: Date) -> String {
        let cleaned = presenter
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let stamp = date.formatted(.dateTime.day().month(.abbreviated).year())
        return cleaned.isEmpty ? "Screen - \(stamp)" : "\(String(cleaned.prefix(60))) - \(stamp)"
    }
}
