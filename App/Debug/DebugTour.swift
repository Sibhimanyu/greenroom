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
//    toast [title=...] [detail=...] [kind=success|failure|working]  a sample toast, held until `restore`.
//    prompt       a sample upload prompt; its buttons only dismiss, nothing uploads.
//    countdown n=3 [go=true]  the island's countdown, no recording; Cancel/Esc clear it.
//    queue [kind=failure] [hold=secs]  a toast then a prompt back to back; one shows, one waits.
//    resetMeetingTip  show the meeting window's one-time "Control bar" tip again
//                 (clears UserDefaults key meetingShrinkTip.done; the same as
//                 `defaults delete <bundle id> meetingShrinkTip.done`).
//    status step=1..5 | live=true [recording=true] [hold=secs] | fail="..." | clear
//                 drives the notch status pill with sample data only; nothing starts.
//    film page=home|sessions [secs=1]  films the page change (DebugFilm.swift).
//    tree         dump the main window's view tree to <dir>/tree.txt.
//    popup name=look|camera|share|layout|record|mic|more|none  opens that Home dock
//                 popup (the same @State its button toggles); `none` closes it.
//    popupScroll y=<points> [steps=20]  scrolls the open popup's NSScrollView to y
//                 from the top in `steps` runloop-spaced steps; returns the
//                 popup content's hosting-view layout passes (and ms) and root
//                 body passes during the scroll.
//    cameraSwitch on=true|false  the Camera popup's "Switch to the camera you're
//                 facing" (its content grows); `restore` puts the setting back.
//                 Use `shareKind kind=window` to grow the open Share popup.
//    showHere on|off  lets the main window join the Space the owner is on (a
//                 full-screen app's too) and orders it front WITHOUT activating,
//                 so ScreenCaptureKit can read it (it fails, -3811, for windows on
//                 another Space). `off` and `restore` put the behaviour back.
//    shot also writes <name>-popup.png (the popup with its parent window,
//                 composited with their window shadows on a transparent
//                 backdrop) while a popup is open.
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
                case "film":
                    // Films the page change asked for (DebugFilm.swift).
                    guard let c = CoordinatorController.shared else { throw TourError("no coordinator") }
                    let page = info["page"] ?? "home"
                    extra = try await DebugFilm.film(info, dir: dir) {
                        c.mainPage = page == "sessions" ? .sessions : .home
                    }
                case "sessionWindowSize": try resize(info)
                case "restore": await restore()
                case "homeMode":
                    guard let c = CoordinatorController.shared,
                          let m = MeetingMode.allCases.first(where: { "\($0)" == info["mode"] })
                    else { throw TourError("bad mode") }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { c.meetingMode = m }
                case "splash":
                    // Plays the launch again over the main window.
                    guard let window = MainWindow.current else { throw TourError("no main window") }
                    LaunchSplashCover.replay(over: window)
                case "hintCards":
                    // Renders every dock hover card to hint-<name>.png, off screen.
                    extra["written"] = DockHintCards.render(dir: dir, dark: info["mode"] != "light")
                case "homeCard":
                    // face=picture|screen: which face Home's preview card shows.
                    NotificationCenter.default.post(name: .debugTourHomeCard, object: nil,
                                                    userInfo: ["screen": info["face"] == "screen"])
                case "homePreview":
                    // shown=true|false: the picture card opened or folded away.
                    // `restore` folds it.
                    // camera=on starts the owner's camera, as the Preview button does;
                    // the default here is camera=off, so a tour never turns it on.
                    savedPreview = false
                    NotificationCenter.default.post(name: .debugTourHomePreview, object: nil,
                                                    userInfo: ["shown": info["shown"] == "true",
                                                               "camera": info["camera"] == "on"])
                case "shareKind":
                    // Shows the window-only controls. `restore` puts the saved kind back.
                    guard let c = CoordinatorController.shared,
                          let k = ShareTarget.Kind(rawValue: info["kind"] ?? "") else { throw TourError("bad kind") }
                    if savedShareKind == nil { savedShareKind = c.shareTarget.kind }
                    c.shareTarget.kind = k
                case "toast":
                    let kind: ToastController.Kind = ["failure": .failure, "working": .working][info["kind"] ?? ""] ?? .success
                    ToastController.show(info["title"] ?? "Clipped the last 5 min",
                                         detail: info["detail"] ?? "Sample toast from the debug tour",
                                         kind: kind, dismissAfter: nil)
                case "prompt":
                    samplePrompt()
                case "countdown":
                    // n=3: the island's countdown on sample data; nothing records.
                    // Esc and Cancel clear it. `restore` clears it too.
                    let n = max(1, min(10, Int(info["n"] ?? "") ?? 3))
                    if info["go"] == "true" {
                        NotchStatusController.shared.countdownGo()
                    } else {
                        NotchStatusController.shared.setCountdown(n) { NotchStatusController.shared.setCountdown(nil) }
                    }
                case "queue":
                    // A toast then an upload prompt back to back: one shows,
                    // the other waits its turn. kind=failure for a failure toast.
                    let kind: ToastController.Kind = info["kind"] == "failure" ? .failure : .success
                    ToastController.show(info["title"] ?? "Clipped the last 5 min",
                                         detail: info["detail"], kind: kind,
                                         dismissAfter: info["hold"].flatMap(Double.init) ?? ToastController.automatic)
                    samplePrompt()
                case "status": extra = status(info)
                case "resetMeetingTip": MeetingShrinkTip.reset()
                case "tree": tree(dir: dir)
                case "popup":
                    NotificationCenter.default.post(name: .debugTourPopup, object: nil,
                                                    userInfo: ["name": info["name"] ?? "none"])
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    if info["name"] != "none" {
                        guard let p = popupPanel() else { throw TourError("no popup panel opened") }
                        extra["panelIsKey"] = p.isKeyWindow
                        extra["panelFrame"] = [p.frame.minX, p.frame.minY, p.frame.width, p.frame.height]
                    }
                case "popupScroll": extra = try await popupScroll(info)
                case "cameraSwitch":
                    // on=true|false: "Switch to the camera you're facing", so the
                    // Camera popup grows while open. `restore` puts it back.
                    guard let c = CoordinatorController.shared else { throw TourError("no coordinator") }
                    if savedCameraSettings == nil { savedCameraSettings = c.cameraDirectorSettings }
                    c.cameraDirectorSettings.enabled = info["on"] != "false"
                case "showHere":
                    guard let w = MainWindow.current else { throw TourError("no main window") }
                    if info["on"] != "false" && info["mode"] != "off" {
                        if savedBehavior == nil { savedBehavior = w.collectionBehavior }
                        w.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
                        w.orderFront(nil)
                    } else if let b = savedBehavior { w.collectionBehavior = b; savedBehavior = nil }
                    extra["onActiveSpace"] = w.isOnActiveSpace
                case "scroll": try scroll(info)
                case "live": extra = try live(info)
                case "probe": extra = probe()
                default: throw TourError("unknown cmd \(cmd)")
                }
                writeLast(dir: dir, ["ok": true, "cmd": cmd, "seq": mySeq].merging(extra) { a, _ in a })
            } catch {
                writeLast(dir: dir, ["ok": false, "cmd": cmd, "seq": mySeq, "error": "\(error)"])
            }
        }
    }

    private static func samplePrompt() {
        UploadPromptCard.show(
            title: "Upload this recording to YouTube?",
            detail: "Class \u{00B7} 14 Nov \u{00B7} 982 KB \u{00B7} Unlisted",
            help: "Debug tour: nothing is uploaded. The file stays in Documents/Greenroom either way.",
            timeout: 600, onUpload: {}, onDismiss: {})
    }

    /// Sample data only. The buttons just fold the pill; they never reach the
    /// coordinator, so "Try again" cannot start a meeting.
    private static func status(_ info: [String: String]) -> [String: Any] {
        let pill = NotchStatusController.shared
        let fold: () -> Void = { NotchStatusController.shared.clear() }
        let labels = ["Workspace", "Picture", "Creating meeting", "Meeting", "Recording", "Tiling windows"]
        func put(_ input: NotchInput) { pill.update(input, onAction: fold, onDismiss: fold) }
        if info["clear"] != nil {
            pill.clear()
            return [:]
        }
        if let message = info["fail"] {
            let n = max(1, min(labels.count, Int(info["step"] ?? "") ?? 2))
            var steps = labels.enumerated().map { NotchStep(label: $1, state: $0 < n - 1 ? .done : .pending) }
            steps[n - 1].state = .failed
            put(NotchInput(steps: steps, failure: message, detail: "Sample failure from the debug tour"))
            return [:]
        }
        if info["live"] == "true" {
            let recording = info["recording"] == "true"
            pill.liveHold = info["hold"].flatMap(Double.init) ?? 12
            put(NotchInput(steps: labels.map {
                NotchStep(label: $0, state: $0 == "Recording" && !recording ? .skipped : .done)
            }))
            put(NotchInput())
            return [:]
        }
        let n = max(1, min(labels.count, Int(info["step"] ?? "") ?? 1))
        put(NotchInput(steps: labels.enumerated().map {
            NotchStep(label: $1, state: $0 < n - 1 ? .done : ($0 == n - 1 ? .active : .pending))
        }, detail: "Sample status from the debug tour"))
        return [:]
    }

    /// Real sessions, for an agent the owner has asked to test end to end
    /// (2026-11-16). Unlike every other command these DO start things:
    ///   live what=record app=<bundle id> [title=...]  a Record-view take of one window
    ///   live what=stopRecord                          stops the take, no question
    ///   live what=meeting                             a new meeting (Create mode), no one invited
    ///   live what=end                                 ends the session, no question
    ///   live what=size to=window|bar             moves the live meeting
    private static func putBack(_ c: CoordinatorController) {
        if let savedTarget { c.shareTarget = savedTarget }
        if let savedMode { c.meetingMode = savedMode }
        savedTarget = nil; savedMode = nil
    }

    private static func live(_ info: [String: String]) throws -> [String: Any] {
        guard let c = CoordinatorController.shared else { throw TourError("no coordinator") }
        switch info["what"] ?? "" {
        case "record":
            var target = c.shareTarget
            if savedTarget == nil { savedTarget = target }
            target.kind = .window
            target.appBundleID = info["app"] ?? ""
            let bundle = info["app"] ?? ""
            target.appName = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?
                .localizedName ?? bundle
            target.windowTitle = info["title"] ?? ""
            c.shareTarget = target
            if savedMode == nil { savedMode = c.meetingMode }
            c.meetingMode = .record
            c.start()
        case "stopRecord":
            c.stopRecordingSession()
            putBack(c) // the owner's own choices come back at once: a relaunch forgets what was saved
        case "meeting":
            if savedMode == nil { savedMode = c.meetingMode }
            c.meetingMode = .create
            c.start()
        case "end":
            c.stop()
            putBack(c)
        case "size":
            guard let to = MeetingSize(rawValue: info["to"] ?? "") else { throw TourError("bad size") }
            c.moveMeeting(to: to)
        case "putBack":
            putBack(c)
        case "people":
            // The bar's People button, as a click on it does.
            guard let controls = c.meetingControls else { throw TourError("no meeting controls") }
            controls.showPeople()
        case "fail":
            // A long failure on the island, as a real start failure shows it.
            NotchStatusController.shared.update(
                NotchInput(failure: info["message"] ?? "Video didn't start",
                           detail: info["detail"] ?? "Zoom refused the camera subscription three times (code 7, requests came too quickly). Greenroom will try again once the camera is back on; until then the meeting window shows your class."),
                onAction: {}, onDismiss: {})
        case "failOpen":
            NotchStatusController.shared.debugSetFailureOpen(info["open"] != "false")
        case "clearFail":
            NotchStatusController.shared.update(NotchInput(), onAction: {}, onDismiss: {})
        default:
            throw TourError("bad what")
        }
        return [:]
    }
    private static var savedTarget: ShareTarget?
    private static var savedMode: MeetingMode?

    /// What is on screen right now: the session, the front app, and every
    /// visible Greenroom window with its frame (CG top-left points), level and
    /// whether it is on the desktop in view.
    private static func probe() -> [String: Any] {
        guard let c = CoordinatorController.shared else { return [:] }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let windows: [[String: Any]] = NSApp.windows.filter(\.isVisible).map { w in
            let f = w.frame
            return ["title": w.title, "class": "\(type(of: w))", "level": w.level.rawValue,
                    "onActiveSpace": w.isOnActiveSpace, "alpha": w.alphaValue,
                    "frame": [f.minX, mainHeight - f.maxY, f.width, f.height].map { Int($0) }]
        }
        var out: [String: Any] = [
            "front": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
            "isRunning": c.isRunning, "stageLive": c.stageLive, "isRecording": c.isRecording,
            "recordOnly": c.recordOnlyActive, "meetingSize": c.meetingSize.rawValue,
            "meetingWindowShowing": ParticipantGridWindowController.meetingWindowIsShowing,
            "peoplePopOut": PeoplePopOutController.isOpen, "peopleRows": PeoplePopOutController.debugRowCount,
            "failureOpen": NotchStatusController.shared.debugFailureOpen, "barVisible": MeetingControlBarController.isVisible,
            "island": "\(NotchStatusController.shared.debugContent)",
            "windows": windows]
        if let r = c.capturedScreenFrame() { out["captured"] = [r.minX, r.minY, r.width, r.height].map { Int($0) } }
        return out
    }

    private static var savedShareKind: ShareTarget.Kind?
    private static var savedPreview: Bool?

    struct TourError: Error, CustomStringConvertible {
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
            ChatWindowController.close()
            closeEditor()
            for w in opened where !MainWindow.matches(w) { w.close() }
            opened.removeAll()
            for _ in 0..<40 where c.isStopping {
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
        case "editor":
            guard let p = ScreenroomLibrary.presentations().first(where: { $0.recording != nil }),
                  let url = p.recording else { throw TourError("no recording") }
            guard let editor else { throw TourError("bridge not ready") }
            c.mainPage = .editor(p.folder.path) // as the Edit button does
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
        if ["settings", "chat"].contains(page) {
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

    /// `scroll y=<points>`: scrolls the biggest NSScrollView of the topmost visible
    /// non-main window (the Settings page) to y points from its top. No events.
    private static func scroll(_ info: [String: String]) throws {
        guard let y = info["y"].flatMap(Double.init) else { throw TourError("y required") }
        func scrollViews(_ v: NSView) -> [NSScrollView] {
            ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap(scrollViews)
        }
        let candidates = NSApp.windows.filter { $0.isVisible && !MainWindow.matches($0) }
            .compactMap { $0.contentView }.flatMap(scrollViews)
        guard let sv = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
              let clip = Optional(sv.contentView) else { throw TourError("no scroll view") }
        clip.scroll(to: NSPoint(x: 0, y: clip.documentRect.minY + CGFloat(y)))
        sv.reflectScrolledClipView(clip)
    }

    /// Writes the main window's NSView tree (class and frame) to <dir>/tree.txt.
    private static func tree(dir: String) {
        var out = ""
        func walk(_ v: NSView, _ depth: Int) {
            out += String(repeating: " ", count: depth) + "\(type(of: v)) \(v.frame)\n"
            for c in v.subviews { walk(c, depth + 1) }
        }
        if let w = MainWindow.current { out += "WIN frame \(w.frame) layout \(w.contentLayoutRect) minSize \(w.contentMinSize)\n" }
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
        ChatWindowController.close()
        for w in opened where !MainWindow.matches(w) { w.close() }
        opened.removeAll()
        NotchStatusController.shared.clearAll()
        NotchStatusController.shared.liveHold = NotchStatusRules.liveHold
        if let shown = savedPreview {
            NotificationCenter.default.post(name: .debugTourHomePreview, object: nil, userInfo: ["shown": shown])
            savedPreview = nil
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        if let o = original {
            NSApp.appearance = o.appearance
            if let f = o.frame { MainWindow.current?.setFrame(f, display: true, animate: false) }
        }
        original = nil
        if let k = savedShareKind { c.shareTarget.kind = k; savedShareKind = nil }
        NotificationCenter.default.post(name: .debugTourPopup, object: nil, userInfo: ["name": "none"])
        if let b = savedBehavior { MainWindow.current?.collectionBehavior = b; savedBehavior = nil }
        if let cs = savedCameraSettings { c.cameraDirectorSettings = cs; savedCameraSettings = nil }
        try? await Task.sleep(nanoseconds: 300_000_000)
    }
    private static var savedBehavior: NSWindow.CollectionBehavior?
    private static var savedCameraSettings: CameraDirectorSettings?

    /// The open greenroomPopover panel: a visible child panel of the main window.
    private static func popupPanel() -> NSWindow? {
        MainWindow.current?.childWindows?.first { $0 is NSPanel && $0.isVisible }
    }

    private static func popupScroll(_ info: [String: String]) async throws -> [String: Any] {
        guard let y = info["y"].flatMap(Double.init) else { throw TourError("y required") }
        guard let panel = popupPanel(), let root = panel.contentView else { throw TourError("no popup open") }
        func scrollViews(_ v: NSView) -> [NSScrollView] {
            ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap(scrollViews)
        }
        guard let sv = scrollViews(root).max(by: { $0.frame.height < $1.frame.height }) else {
            throw TourError("no scroll view in popup")
        }
        let clip = sv.contentView
        let steps = max(1, Int(info["steps"] ?? "") ?? 20)
        let start = clip.bounds.minY
        // Clamped to the real scroll range, as a wheel would leave it.
        let maxY = max(-sv.contentInsets.top, clip.documentRect.height + sv.contentInsets.bottom - clip.bounds.height)
        let target = min(max(-sv.contentInsets.top, CGFloat(y) - sv.contentInsets.top), maxY)
        let before = PopoverDebug.layoutPasses
        let beforeTime = PopoverDebug.layoutTime
        let beforeBodies = PopoverDebug.bodyPasses
        for i in 1...steps {
            let t = start + (target - start) * CGFloat(i) / CGFloat(steps)
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: t))
            sv.reflectScrolledClipView(clip)
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        return ["layoutPassesDuringScroll": PopoverDebug.layoutPasses - before, "steps": steps,
                "minY": -sv.contentInsets.top, "maxY": maxY,
                "layoutMillisDuringScroll": (PopoverDebug.layoutTime - beforeTime) * 1000,
                "rootBodyPassesDuringScroll": PopoverDebug.bodyPasses - beforeBodies,
                "clipY": clip.bounds.minY, "documentHeight": clip.documentRect.height,
                "visibleHeight": clip.bounds.height]
    }

    /// CGWindowListCreateImageFromArray, which the macOS 15 SDK marks
    /// unavailable to Swift, looked up at run time. Global display space,
    /// top-left origin. Front-to-back order of `ids`.
    private static func legacyComposite(ids: [Int], rect: CGRect) -> CGImage? {
        typealias Fn = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray") else { return nil }
        let fn = unsafeBitCast(sym, to: Fn.self)
        var pointers = ids.map { UnsafeRawPointer(bitPattern: $0) }
        guard let array = CFArrayCreate(nil, &pointers, pointers.count, nil) else { return nil }
        // kCGWindowImageBestResolution (1 << 3); shadows are included by default.
        return fn(rect, array, 1 << 3)?.takeRetainedValue()
    }

    /// The popup and its parent window, composited from the display with only
    /// those two windows included, so the popup's window shadow shows.
    private static func popupShot(name: String, dir: String, content: SCShareableContent) async throws -> String? {
        let ids: (panel: Int, main: Int, rect: CGRect, screenH: CGFloat)? = await MainActor.run {
            guard let p = popupPanel(), let m = MainWindow.current, let screen = m.screen else { return nil }
            let r = p.frame.union(m.frame).insetBy(dx: -40, dy: -40)
            return (p.windowNumber, m.windowNumber, r, screen.frame.maxY)
        }
        if let ids {
            let d: [String: Any] = ["rect": [ids.rect.minX, ids.rect.minY, ids.rect.width, ids.rect.height],
                                    "screenH": ids.screenH,
                                    "scWindows": content.windows.filter { [ids.panel, ids.main].contains(Int($0.windowID)) }
                                        .map { ["id": Int($0.windowID), "frame": [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height], "layer": $0.windowLayer] },
                                    "displays": content.displays.map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height] }]
            if let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted]) {
                try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-popup.json"))
            }
        }
        // The CoreGraphics composite first: it draws the window shadows (the
        // thing under review) on a transparent backdrop, reads windows on
        // another Space, and needs no SCDisplay (absent while the screen sleeps).
        if let ids, let cg = legacyComposite(ids: [ids.panel, ids.main],
                                             rect: CGRect(x: ids.rect.minX, y: ids.screenH - ids.rect.maxY,
                                                          width: ids.rect.width, height: ids.rect.height)),
           let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            let file = "\(name)-popup.png"
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(file))
            return file
        }
        guard let ids,
              let scPanel = content.windows.first(where: { Int($0.windowID) == ids.panel }),
              let scMain = content.windows.first(where: { Int($0.windowID) == ids.main }),
              let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: scMain.frame.midX, y: scMain.frame.midY)) })
        else { return nil }
        let filter = SCContentFilter(display: display, including: [scMain, scPanel])
        let cfg = SCStreamConfiguration()
        // sourceRect is in display points, top-left origin.
        let top = ids.screenH - ids.rect.maxY
        cfg.sourceRect = CGRect(x: ids.rect.minX - display.frame.minX, y: top - display.frame.minY,
                                width: ids.rect.width, height: ids.rect.height)
        cfg.width = Int(ids.rect.width * 2)
        cfg.height = Int(ids.rect.height * 2)
        cfg.showsCursor = false
        cfg.captureResolution = .best
        cfg.ignoreShadowsDisplay = false
        cfg.backgroundColor = .white
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
        let file = "\(name)-popup.png"
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(file))
        return file
    }

    // MARK: Capture

    private static func shot(_ info: [String: String], dir: String) async throws -> [String: Any] {
        let name = info["name"] ?? "shot"
        try? await Task.sleep(nanoseconds: 600_000_000)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let me = Bundle.main.bundleIdentifier
        let windows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == me
                && (($0.frame.width > 120 && $0.frame.height > 80 && $0.windowLayer == 0)
                    || $0.title == "Status")
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
            // Position on its own screen, in points from the screen's top-left,
            // plus the menu-bar and right-edge gaps, so placement can be checked.
            // NSWindow / NSScreen are MainActor-only, and shot() runs off it. Compare as Int: CGWindowID(-1) traps for windows without a number.
            let wid = w.windowID
            let placement: [String: Any]? = await MainActor.run {
                guard let ns = NSApp.windows.first(where: { $0.windowNumber == Int(wid) }),
                      let screen = ns.screen else { return nil }
                let sf = screen.frame, vf = screen.visibleFrame
                // The message panel's frame includes its shadow room: measure the cards.
                let f = ns.frame
                let card = f
                var statusInfo: [String: Any] = [:]
                if ns.title == "Status" {
                    let notch = NotchStatusController.shared.debugNotch
                    statusInfo["screenFrame"] = [sf.minX, sf.minY, sf.width, sf.height]
                    statusInfo["topGapToScreenTop"] = sf.maxY - f.maxY
                    if let n = notch {
                        statusInfo["notchRect"] = [n.minX - sf.minX, sf.maxY - n.maxY, n.width, n.height]
                        statusInfo["panelMidXMinusNotchMidX"] = f.midX - n.midX
                    } else { statusInfo["notchRect"] = "none: fallback placement" }
                    statusInfo["level"] = ns.level.rawValue
                    statusInfo["content"] = "\(NotchStatusController.shared.debugContent)"
                }
                return statusInfo.merging(["screenRelative": [f.minX - sf.minX, sf.maxY - f.maxY, f.width, f.height],
                        "gapBelowMenuBar": vf.maxY - card.maxY,
                        "gapFromRightEdge": vf.maxX - card.maxX,
                        "screenSize": [sf.width, sf.height]] as [String: Any]) { a, _ in a }
            }
            if let placement { entry.merge(placement) { $1 } }
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
        do {
            if let file = try await popupShot(name: name, dir: dir, content: content) {
                entries.append(["title": "popup", "file": file])
            }
        } catch { errors.append("popup: \(error)") }
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
extension Notification.Name {
    static let debugTourHomePreview = Notification.Name("com.greenroom.debug.tour.homePreview")
    static let debugTourHomeCard = Notification.Name("com.greenroom.debug.tour.homeCard")
    static let debugTourPopup = Notification.Name("com.greenroom.debug.tour.popup")
}


/// The dock's hover cards, drawn to PNGs with sample values, for review.
@MainActor enum DockHintCards {
    static func render(dir: String, dark: Bool) -> [String] {
        let sampleLayout = CoordinatorController.shared?.layoutLibrary.templates.first { $0.pieceCount > 0 }?.oneDisplay
        let cards: [(String, DockHintContent)] = [
            ("look-circle", .init(title: "Look", value: "Circle", text: "How you appear over what you share.",
                                  visual: DockHintVisual.look(.circle, cameraOff: false))),
            ("look-presenter", .init(title: "Look", value: "Presenter", text: "How you appear over what you share.",
                                     visual: DockHintVisual.look(.presenterLarge, cameraOff: false))),
            ("share-window", .init(title: "Share", value: "Keynote", text: "What everyone sees behind you.",
                                   visual: DockHintVisual.share(.window, shape: .roundedRectangle, cameraOff: false))),
            ("share-display", .init(title: "Share", value: "Whole screen", text: "What everyone sees behind you.",
                                    visual: DockHintVisual.share(.display, shape: .circle, cameraOff: false))),
            ("share-whiteboard", .init(title: "Share", value: "Whiteboard", text: "What everyone sees behind you.",
                                       visual: DockHintVisual.share(.whiteboard, shape: .square, cameraOff: false))),
            ("camera", .init(title: "Camera", value: "MacBook Pro Camera", text: "Which camera you appear on.",
                             visual: DockHintVisual.camera(off: false))),
            ("mic", .init(title: "Microphone", value: "MacBook Pro Microphone",
                          text: "Which microphone everyone hears, and the recording takes.",
                          visual: DockHintVisual.microphone)),
            ("layout", .init(title: "Layout", value: "Sample", text: "Where Start puts the meeting, the chat and your apps.",
                             visual: DockHintVisual.layout(sampleLayout) {
                                 LayoutPageContent.look($0, customUIMode: false, canMoveApps: true)
                             })),
            ("layout-none", .init(title: "Layout", value: "None", text: "Where Start puts the meeting, the chat and your apps.",
                                  visual: DockHintVisual.layout(nil) { _ in fatalError() })),
            ("record-hand", .init(title: "Record", value: "Manual", text: "Recording starts when you press Record.",
                                  visual: DockHintVisual.record(withMeeting: false))),
            ("record-auto", .init(title: "Record", value: "Auto-record",
                                  text: "Recording starts with the meeting.", visual: DockHintVisual.record(withMeeting: true))),
        ]
        var written: [String] = []
        for (name, hint) in cards {
            let view = DockHintCard(hint: hint)
                .background(dark ? Color(white: 0.17) : Color(white: 0.96))
                .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage else { continue }
            let url = URL(fileURLWithPath: dir).appendingPathComponent("hint-\(name).png")
            let rep = NSBitmapImageRep(cgImage: image)
            if let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: url)) != nil {
                written.append(url.lastPathComponent)
            }
        }
        return written
    }
}
#endif
