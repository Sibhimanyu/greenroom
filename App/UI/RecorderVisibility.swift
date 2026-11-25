//
//  RecorderVisibility.swift
//  Greenroom
//
//  Applies PresenceRecorderRules to real windows. Every window whose
//  sharingType the "Show Greenroom on screen in other apps' recordings" switch
//  decides is registered here with its kind; the sharingType is set now and
//  again, live, whenever the setting changes. Windows are held weakly. The
//  setup guide registers too and always stays `.none` (credentials).
//
//  This only controls OTHER apps. Greenroom's own capture (StageScreenSource)
//  excludes every Greenroom window through the app-wide filter, whatever
//  sharingType says.
//
import AppKit

@MainActor
enum RecorderVisibility {
    private final class Box { weak var window: NSWindow?; let kind: PresenceRecorderRules.WindowKind
        init(_ w: NSWindow, _ k: PresenceRecorderRules.WindowKind) { window = w; kind = k } }
    private static var boxes: [Box] = []
    private static var observer: NSObjectProtocol?

    /// The camera state the bubble is showing now (Only me is never recordable). The coordinator sets it
    /// whenever the bubble is refreshed.
    static var cameraState: CameraState = .everyoneAndMe {
        didSet { if cameraState != oldValue { applyAll() } }
    }

    /// Sets the window's sharingType now and keeps it current.
    static func track(_ window: NSWindow, as kind: PresenceRecorderRules.WindowKind) {
        boxes.removeAll { $0.window == nil || $0.window === window }
        boxes.append(Box(window, kind))
        apply(window, kind)
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { applyAll() }
        }
    }

    /// The sharingType the rules give a kind right now.
    static func sharingType(for kind: PresenceRecorderRules.WindowKind) -> NSWindow.SharingType {
        PresenceRecorderRules.sharing(for: kind, visibleToRecorders: PresenceRecorderRules.storedVisibleToRecorders,
                                      cameraState: cameraState) == .readOnly ? .readOnly : .none
    }

    private static func apply(_ window: NSWindow, _ kind: PresenceRecorderRules.WindowKind) {
        let wanted = sharingType(for: kind)
        if window.sharingType != wanted { window.sharingType = wanted }
    }

    private static func applyAll() {
        boxes.removeAll { $0.window == nil }
        for box in boxes { if let w = box.window { apply(w, box.kind) } }
    }
}
