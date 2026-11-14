//
//  MenuBarModel.swift
//  Greenroom
//
//  The pure half of the menu bar menu: (state, readiness, last session,
//  shortcuts) in, an ordered list of items out. No SwiftUI, no AppKit, no
//  coordinator, so the test target compiles this file as it is and a
//  hidden-or-shown mistake is a failing test rather than something found by
//  clicking. MenuBarView.swift draws the list and runs the actions.
//
//  "A native menu that follows state" (DESIGN.md, 2026-11-13): idle it looks
//  like Home's modes, live it holds the session's controls, and an item that
//  does not apply is absent, never greyed. The one exception is the status
//  header, which is always first and never clickable.
//
import Foundation
import Carbon.HIToolbox

// MARK: - Inputs

/// What the menu needs to know about the session, as plain values.
struct MenuBarState: Equatable {
    /// "Starting...": a meeting is coming up, not yet live.
    var isStarting = false
    /// A meeting is live, or a record-only session is open.
    var isLive = false
    var isStopping = false
    var className = ""
    /// Seconds since the session began; nil before it does.
    var sessionElapsed: TimeInterval?

    var isRecording = false
    var isPaused = false
    var isSavingRecording = false
    /// Seconds of the recording file (frozen while paused).
    var recordingElapsed: TimeInterval?

    var notesShown = false
    /// Snap Windows Back and the speaker tile mean something (an arranged layout).
    var layoutToolsAvailable = true
    var speakerTileHidden = false
    var canToggleSpeakerTile = true
    var canDraw = false
    var isDrawing = false
    /// The layout a start uses. Locked while a session is live: it keeps the
    /// one it started with, so the submenu is hidden rather than greyed.
    var layoutName = ""
    var layoutLocked = false

    var uploadProgress: Double?
    var cuesListening = false
    var cuesPaused = false
    /// The Cues line, already worded (CuesStatus), so this file needs no Cues code.
    var cuesStatusText = ""

    /// A session of any kind is under way.
    var inSession: Bool { isLive || isStarting }
}

/// One thing a start needs that is missing, with where its fix is. The same
/// four Home's readiness pills show.
struct MenuBarProblem: Equatable {
    enum Fix: Equatable { case zoomSettings, cameraPrivacy, micPrivacy, screenPrivacy }
    let fix: Fix
    /// In the pill's own words: "Camera: not allowed".
    let text: String
}

/// The newest session on disk.
struct MenuBarLastSession: Equatable {
    let path: String
    let title: String
    let length: String?
}

// MARK: - Output

enum MenuBarAction: Equatable {
    case newMeeting, joinMeeting, record
    case sessions, openLastSession
    case settings
    case showGreenroom, openGreenroomWindow, checkForUpdates, howItWorks, quit
    case toggleRecording, togglePause
    case toggleNotes, snapBack, toggleSpeakerTile, toggleDrawing
    case endSession
    /// The live header: brings the meeting (or the control bar) forward.
    case showMeeting
    case stopCues
    case fix(MenuBarProblem.Fix)
}

struct MenuBarItem: Equatable {
    enum Kind: Equatable {
        /// Disabled, informational.
        case status
        case action(MenuBarAction)
        /// The Layout submenu; its contents are the layout choices.
        case layoutMenu
        case separator
    }
    var kind: Kind
    var title: String
    /// SF Symbol name.
    var symbol: String?
    var shortcut: KeyCombo?
    var destructive = false
    /// Amber rather than the default colour (needs-attention header).
    var attention = false

    var isSeparator: Bool { kind == .separator }
    var action: MenuBarAction? { if case .action(let a) = kind { return a } else { return nil } }

    static let separator = MenuBarItem(kind: .separator, title: "")
}

// MARK: - Builder

enum MenuBarModel {
    /// The Settings shortcut every Mac app has. Fixed by the system, so it is
    /// not one of the customisable shortcuts.
    static let settingsCombo = KeyCombo(keyCode: UInt32(kVK_ANSI_Comma), modifiers: KeyCombo.command)

    static func items(state: MenuBarState,
                      problems: [MenuBarProblem],
                      lastSession: MenuBarLastSession?,
                      shortcuts: ShortcutBindings) -> [MenuBarItem] {
        func key(_ a: ShortcutAction) -> KeyCombo? { shortcuts.combo(for: .action(a)) }
        func action(_ a: MenuBarAction, _ title: String, _ symbol: String,
                    _ combo: KeyCombo? = nil, destructive: Bool = false) -> MenuBarItem {
            MenuBarItem(kind: .action(a), title: title, symbol: symbol, shortcut: combo, destructive: destructive)
        }
        func status(_ title: String, _ symbol: String? = nil, attention: Bool = false) -> MenuBarItem {
            MenuBarItem(kind: .status, title: title, symbol: symbol, attention: attention)
        }

        var out: [MenuBarItem] = []

        if state.inSession {
            out += liveHeader(state)
            out.append(.separator)

            // Recording. While the file is being saved nothing here applies.
            if !state.isSavingRecording {
                if state.isRecording {
                    out.append(action(.togglePause,
                                      state.isPaused ? "Resume Recording" : "Pause Recording",
                                      state.isPaused ? "play.fill" : "pause.fill",
                                      key(.togglePause)))
                    out.append(action(.toggleRecording, "Stop Recording", "stop.circle", key(.toggleRecording)))
                } else if state.isLive {
                    out.append(action(.toggleRecording, "Start Recording", "record.circle", key(.toggleRecording)))
                }
            }
            if let cues = cuesItems(state) { out += cues }
            if out.last?.isSeparator == false { out.append(.separator) }

            var tools: [MenuBarItem] = []
            tools.append(action(.toggleNotes, state.notesShown ? "Hide Notes" : "Show Notes",
                                "note.text", key(.toggleNotes)))
            if state.layoutToolsAvailable {
                tools.append(action(.snapBack, "Snap Windows Back",
                                    "arrow.uturn.backward.square", key(.snapBack)))
                if state.canToggleSpeakerTile {
                    tools.append(action(.toggleSpeakerTile,
                                        state.speakerTileHidden ? "Show Speaker Tile" : "Hide Speaker Tile",
                                        state.speakerTileHidden ? "person.crop.rectangle" : "person.crop.rectangle.badge.minus",
                                        key(.toggleMeeting)))
                }
            }
            if state.canDraw || state.isDrawing {
                tools.append(action(.toggleDrawing, state.isDrawing ? "Stop Drawing" : "Draw on the Screen",
                                    "pencil.tip.crop.circle", key(.toggleDrawing)))
            }
            if !state.layoutLocked {
                tools.append(MenuBarItem(kind: .layoutMenu, title: "Layout: \(state.layoutName)",
                                         symbol: "rectangle.3.group"))
            }
            out += tools
            out.append(.separator)

            if !state.isStopping {
                out.append(action(.endSession, "End Session\u{2026}", "xmark.circle", key(.endSession), destructive: true))
                out.append(.separator)
            }
            out.append(action(.showGreenroom, "Show Greenroom", "macwindow", key(.openGreenroom)))
            // While live the main window is out of the way; this is how to bring Home back on purpose.
            out.append(action(.openGreenroomWindow, "Open Greenroom Window", "house"))
            out.append(action(.quit, "Quit Greenroom", "power"))
            return out
        }

        // Idle.
        out.append(idleHeader(problems))
        for p in problems {
            out.append(MenuBarItem(kind: .action(.fix(p.fix)), title: p.text,
                                   symbol: "exclamationmark.triangle", attention: true))
        }
        out.append(.separator)
        out.append(action(.newMeeting, "New Meeting", "video.badge.plus", key(.startClass)))
        out.append(action(.joinMeeting, "Join Meeting\u{2026}", "person.crop.rectangle.badge.plus"))
        out.append(action(.record, "Record\u{2026}", "record.circle"))
        out.append(.separator)
        out.append(MenuBarItem(kind: .layoutMenu, title: "Layout: \(state.layoutName)", symbol: "rectangle.3.group"))
        out.append(.separator)
        out.append(action(.sessions, "Sessions\u{2026}", "rectangle.stack", key(.openSessions)))
        if let last = lastSession {
            let text = [last.title, last.length].compactMap { $0 }.joined(separator: " \u{00B7} ")
            out.append(action(.openLastSession, "Last: \(text)", "clock.arrow.circlepath"))
        }
        out.append(.separator)
        out.append(action(.showGreenroom, "Show Greenroom", "macwindow", key(.openGreenroom)))
        out.append(action(.settings, "Settings\u{2026}", "gearshape", settingsCombo))
        out.append(action(.checkForUpdates, "Check for Updates\u{2026}", "arrow.triangle.2.circlepath"))
        out.append(action(.howItWorks, "How It Works & Privacy\u{2026}", "lock.shield"))
        out.append(.separator)
        out.append(action(.quit, "Quit Greenroom", "power"))
        return out
    }

    // MARK: Headers

    private static func idleHeader(_ problems: [MenuBarProblem]) -> MenuBarItem {
        problems.isEmpty
            ? MenuBarItem(kind: .status, title: "Greenroom \u{00B7} Ready", symbol: "checkmark.circle")
            : MenuBarItem(kind: .status, title: "Greenroom \u{00B7} Needs attention",
                          symbol: "circle.fill", attention: true)
    }

    private static func liveHeader(_ s: MenuBarState) -> [MenuBarItem] {
        var lines: [MenuBarItem] = []
        let name = s.className.trimmingCharacters(in: .whitespaces)
        if s.isStopping {
            lines.append(MenuBarItem(kind: .status, title: "Ending\u{2026}"))
        } else if s.isStarting && !s.isLive {
            lines.append(MenuBarItem(kind: .status, title: "Starting\u{2026}"))
        } else {
            var parts = ["\u{25CF} Live"]
            if !name.isEmpty { parts.append(name) }
            if let e = s.sessionElapsed { parts.append(clock(e)) }
            // Clickable: the way back to the meeting from anywhere.
            lines.append(MenuBarItem(kind: .action(.showMeeting), title: parts.joined(separator: " \u{00B7} ")))
        }
        if s.isSavingRecording {
            lines.append(MenuBarItem(kind: .status, title: "Saving recording\u{2026}"))
        } else if s.isRecording {
            var t = "\u{25CF} Recording"
            if let e = s.recordingElapsed { t += " " + clock(e) }
            if s.isPaused { t += " \u{00B7} Paused" }
            lines.append(MenuBarItem(kind: .status, title: t))
        }
        if let p = s.uploadProgress {
            lines.append(MenuBarItem(kind: .status, title: "Uploading to YouTube \u{00B7} \(Int((p * 100).rounded()))%"))
        }
        return lines
    }

    private static func cuesItems(_ s: MenuBarState) -> [MenuBarItem]? {
        guard s.cuesListening else { return nil }
        return [
            MenuBarItem(kind: .status, title: s.cuesStatusText, symbol: "waveform"),
            MenuBarItem(kind: .action(.stopCues), title: "Stop Cues for This Session", symbol: "waveform.slash"),
        ]
    }

    // MARK: Time

    /// "4:07", "1:02:09". The clock a recording file and a class timer read.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
