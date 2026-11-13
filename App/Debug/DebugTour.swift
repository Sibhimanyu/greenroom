#if DEBUG
//
//  DebugTour.swift
//  Greenroom
//
//  DEBUG-only snapshot and navigation hook, so a reviewer can see the real UI
//  (toolbars, Liquid Glass, video) screen by screen. Debug UI never ships: this
//  whole file is inside #if DEBUG and so is every call to it.
//
//  Listens on DistributedNotificationCenter for "com.greenroom.debug.tour".
//  userInfo is all strings: `cmd` plus its arguments.
//    goto  page=home|sessions|detail|report|record|editor|settings|onboarding|chat [tab=...]
//    appearance  mode=light|dark|system
//    shot  name=... [dir=...]
//    sessionWindowSize  w=... [h=...]
//    tree         dump the main window's view tree to <dir>/tree.txt.
//    restore      Home, original appearance and frame, tour windows closed.
//  Every command writes <dir>/last.json ({"ok":..,"cmd":..,"error":..,"seq":..}).
//
//  Background rules: nothing here activates the app, makes a window key, sends
//  a keystroke or click, or starts a meeting. Windows the tour opens are
//  ordered to the back of the window list, and if SwiftUI's open call pulled
//  focus off the app that was frontmost, that app is handed focus back.
//  Capture is ScreenCaptureKit's desktopIndependentWindow filter, which reads
//  a window's own content even while other apps cover it.
//
import AppKit
import SwiftUI
import ScreenCaptureKit

/// Hands the tour the two things only a view can reach: openWindow and
/// openSettings, plus the shared editor document. Zero-size, draws nothing.
struct DebugTourBridge: View {
    let editor: EditorViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear.frame(width: 0, height: 0).onAppear {
            DebugTour.editor = editor
            DebugTour.openWindowByID = { openWindow(id: $0) }
            DebugTour.openSettingsWindow = { openSettings() }
        }
    }
}

extension Notification.Name {
    /// Posted in-process; object is the tab tag (see SettingsView.tabOrder).
    static let debugTourSettingsTab = Notification.Name("GreenroomDebugTourSettingsTab")
}

@MainActor
enum DebugTour {
    static let name = Notification.Name("com.greenroom.debug.tour")
    static let defaultDir = "/private/tmp/claude-502/-Users-sibhi-zstch1643-squeak-workspaces-greenroom-hong-kong/a8a46d29-7ec2-41d7-960b-ff6744402685/scratchpad/tour"

    static var editor: EditorViewModel?
    static var openWindowByID: ((String) -> Void)?
    static var openSettingsWindow: (() -> Void)?

    private static var started = false
    private static var seq = 0
    private static var original: (appearance: NSAppearance?, frame: NSRect?)?
    private static var opened: [NSWindow] = []
    private static var lastDir = defaultDir

    static func start() {
        guard !started else { return }
        started = true
        DistributedNotificationCenter.default().addObserver(
            forName: name, object: nil, queue: .main
        ) { note in
            let info = (note.userInfo as? [String: Any])?.mapValues { "\($0)" } ?? [:]
            MainActor.assumeIsolated { handle(info) }
        }
    }

    // MARK: Commands

    private static func handle(_ info: [String: String]) {
        let cmd = info["cmd"] ?? ""
        let dir = info["dir"] ?? defaultDir
        lastDir = dir
        seq += 1
        let mySeq = seq
        if original == nil {
            original = (NSApp.appearance, MainWindow.current?.frame)
        }
        Task { @MainActor in
            do {
                var extra: [String: Any] = [:]
                switch cmd {
                case "goto": extra = try await goto(info)
                case "appearance": try appearance(info["mode"] ?? "")
                case "shot": extra = try await shot(info, dir: dir)
                case "sessionWindowSize": try resize(info)
                case "restore": await restore()
                case "homeMode":
                    guard let c = CoordinatorController.shared,
                          let m = MeetingMode.allCases.first(where: { "\($0)" == info["mode"] })
                    else { throw TourError("bad mode") }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { c.meetingMode = m }
                case "shareKind":
                    // Shows the window-only controls. `restore` puts the saved kind back.
                    guard let c = CoordinatorController.shared,
                          let k = ShareTarget.Kind(rawValue: info["kind"] ?? "") else { throw TourError("bad kind") }
                    if savedShareKind == nil { savedShareKind = c.shareTarget.kind }
                    c.shareTarget.kind = k
                case "tree": tree(dir: dir)
                default: throw TourError("unknown cmd \(cmd)")
                }
                writeLast(dir: dir, ["ok": true, "cmd": cmd, "seq": mySeq].merging(extra) { a, _ in a })
            } catch {
                writeLast(dir: dir, ["ok": false, "cmd": cmd, "seq": mySeq, "error": "\(error)"])
            }
        }
    }

    private static var savedShareKind: ShareTarget.Kind?

    private struct TourError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    private static func goto(_ info: [String: String]) async throws -> [String: Any] {
        guard let c = CoordinatorController.shared else { throw TourError("no coordinator") }
        let page = info["page"] ?? ""
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        let previous = NSWorkspace.shared.frontmostApplication
        var note: [String: Any] = [:]
        switch page {
        case "home":
            c.showOnboarding = false
            c.mainPage = .home
            // The opposite of getReadyToRecord, as the Record view's Done does.
            if c.recordOnlyActive, !c.isRecording { c.stopRecordingSession() }
            ChatWindowController.close()
            closeEditor()
            for w in opened where !MainWindow.matches(w) { w.close() }
            opened.removeAll()
            for _ in 0..<40 where c.recordStudioShown || c.isStopping {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        case "sessions":
            c.mainPage = .sessions
        case "detail":
            guard let p = ScreenroomLibrary.presentations().first(where: { $0.recording != nil })
            else { throw TourError("no session with a video") }
            c.mainPage = .detail(p.folder.path)
        case "report":
            guard let p = ScreenroomLibrary.presentations().first(where: {
                FileManager.default.fileExists(atPath: ScreenroomAnalysis.url(in: $0.folder).path)
                    || FileManager.default.fileExists(atPath: ScreenroomReport.url(in: $0.folder).path)
            }) else {
                note["skipped"] = "no analysed session"
                return note
            }
            c.mainPage = .report(p.folder.path)
        case "record":
            // Same call as Home's Record mode (getReadyToRecord). It opens the
            // camera/screen preview; it does not record or start a meeting.
            c.mainPage = .home
            c.getReadyToRecord()
            note["note"] = "camera/screen preview started; nothing recording"
        case "editor":
            guard let p = ScreenroomLibrary.presentations().first(where: { $0.recording != nil }),
                  let url = p.recording else { throw TourError("no recording") }
            guard let open = openWindowByID, let editor else { throw TourError("bridge not ready") }
            open("editor")                      // as the Edit button does
            await editor.load(url: url)
        case "settings":
            guard let open = openSettingsWindow else { throw TourError("bridge not ready") }
            open()
            try? await Task.sleep(nanoseconds: 300_000_000)
            NotificationCenter.default.post(name: .debugTourSettingsTab, object: info["tab"] ?? "webcam")
        case "onboarding":
            c.presentOnboarding()               // the Setup guide button's call
        case "chat":
            ChatWindowController.show(chat: c.zoomChatBridge)
        default:
            throw TourError("unknown page \(page)")
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
        // Anything new goes to the back; focus goes back to whoever had it.
        for w in NSApp.windows where !before.contains(ObjectIdentifier(w)) && w.isVisible {
            opened.append(w)
        }
        if ["editor", "settings", "chat"].contains(page) {
            for w in NSApp.windows where !MainWindow.matches(w) && w.isVisible
                && (opened.contains(w) || page == "chat") { w.orderBack(nil) }
        }
        if let previous, !previous.isActive, previous.bundleIdentifier != Bundle.main.bundleIdentifier {
            previous.activate(options: [])      // give focus back, never take it
        }
        return note
    }

    private static func appearance(_ mode: String) throws {
        switch mode {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "system": NSApp.appearance = nil
        default: throw TourError("unknown mode \(mode)")
        }
    }

    private static func resize(_ info: [String: String]) throws {
        guard let w = MainWindow.current else { throw TourError("no main window") }
        guard let width = info["w"].flatMap(Double.init) else { throw TourError("w required") }
        let height = info["h"].flatMap(Double.init) ?? Double(w.frame.height)
        var f = w.frame
        f.origin.y += f.height - CGFloat(height)    // keep the top edge
        f.size = NSSize(width: width, height: height)
        w.setFrame(f, display: true, animate: false)
    }

    /// Writes the main window's NSView tree (class and frame) to <dir>/tree.txt.
    private static func tree(dir: String) {
        var out = ""
        func walk(_ v: NSView, _ depth: Int) {
            out += String(repeating: " ", count: depth) + "\(type(of: v)) \(v.frame)\n"
            for c in v.subviews { walk(c, depth + 1) }
        }
        if let v = MainWindow.current?.contentView { walk(v, 0) }
        try? out.write(toFile: dir + "/tree.txt", atomically: true, encoding: .utf8)
    }

    private static func closeEditor() {
        for w in NSApp.windows where w.isVisible && !MainWindow.matches(w) && w.level == .normal
            && (w.identifier?.rawValue.contains("editor") == true || w.title.lowercased().contains("editor")) {
            w.close()
        }
    }

    private static func restore() async {
        guard let c = CoordinatorController.shared else { return }
        c.showOnboarding = false
        c.mainPage = .home
        if c.recordOnlyActive, !c.isRecording { c.stopRecordingSession() }
        ChatWindowController.close()
        for w in opened where !MainWindow.matches(w) { w.close() }
        opened.removeAll()
        if let o = original {
            NSApp.appearance = o.appearance
            if let f = o.frame { MainWindow.current?.setFrame(f, display: true, animate: false) }
        }
        original = nil
        if let k = savedShareKind { c.shareTarget.kind = k; savedShareKind = nil }
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    // MARK: Capture

    private static func shot(_ info: [String: String], dir: String) async throws -> [String: Any] {
        let name = info["name"] ?? "shot"
        try? await Task.sleep(nanoseconds: 600_000_000)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let me = Bundle.main.bundleIdentifier
        let windows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == me && $0.frame.width > 120 && $0.frame.height > 80
                && $0.windowLayer == 0
        }
        var entries: [[String: Any]] = []
        var errors: [String] = []
        for (i, w) in windows.enumerated() {
            let title = (w.title?.isEmpty == false ? w.title! : "window\(i)")
            let safe = title.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
            let file = "\(name)-\(safe).png"
            var entry: [String: Any] = [
                "title": w.title ?? "", "file": file, "isOnScreen": w.isOnScreen,
                "frame": [w.frame.origin.x, w.frame.origin.y, w.frame.width, w.frame.height]]
            if !w.isOnScreen { entry["warning"] = "isOnScreen false" }
            do {
                let filter = SCContentFilter(desktopIndependentWindow: w)
                let cfg = SCStreamConfiguration()
                cfg.width = Int(w.frame.width * 2)
                cfg.height = Int(w.frame.height * 2)
                cfg.showsCursor = false
                cfg.captureResolution = .best
                // SCStream error -3811 ("failed to start") comes and goes,
                // mostly for windows behind others: retry after 0.5 s, and
                // again after 1 s.
                var image: CGImage?
                var lastError: Error?
                for wait in [0.0, 0.5, 1.0] {
                    if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                    do {
                        image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                        break
                    } catch { lastError = error }
                }
                guard let image else { throw lastError ?? TourError("capture failed") }
                let rep = NSBitmapImageRep(cgImage: image)
                guard let png = rep.representation(using: .png, properties: [:]) else {
                    throw TourError("png encode failed")
                }
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(file))
            } catch {
                entry["error"] = "\(error)"
                errors.append("\(title): \(error)")
            }
            entries.append(entry)
        }
        if windows.isEmpty { errors.append("no Greenroom windows found") }
        let manifest: [String: Any] = ["name": name, "windows": entries, "errors": errors]
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).json"))
        }
        if !errors.isEmpty { throw TourError(errors.joined(separator: "; ")) }
        let offscreen = entries.filter { ($0["isOnScreen"] as? Bool) == false }.count
        return offscreen > 0 ? ["warning": "\(offscreen) window(s) report isOnScreen false"] : [:]
    }

    private static func writeLast(dir: String, _ dict: [String: Any]) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("last.json"))
        }
    }
}
#endif
