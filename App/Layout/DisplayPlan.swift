//
//  DisplayPlan.swift
//  Greenroom
//
//  The decisions made when a display is plugged in or pulled out, with no
//  AppKit in them so they can be checked on their own:
//   - which display the screen capture should be on, and when to rebuild it;
//   - where a window goes when the screen it was on has gone.
//
import CoreGraphics
import Foundation

enum DisplayPlan {

    /// One connected display, as the capture decision needs to know it.
    struct Display: Equatable {
        var uuid: String
        var pixelSize: CGSize
    }

    /// What the running screen capture was built against.
    struct Capture: Equatable {
        /// The display it is on. nil when no capture is running (permission
        /// off, nothing shared): there is nothing to move.
        var activeUUID: String?
        /// The display the person chose; empty means "the main one".
        var preferredUUID: String
        /// True when `activeUUID` is the main display only because the chosen
        /// one was not plugged in.
        var fellBack: Bool
        var activePixelSize: CGSize?
        /// A whole display, as opposed to an app or one window.
        var isWholeDisplay: Bool
    }

    enum Decision: Equatable {
        case keep
        /// Rebuild the capture beside the old one; the old one stays on
        /// screen until the new one has its first frame. `reason` is the
        /// plain sentence for the log.
        case rebuild(String)
    }

    /// The display a capture should use: the chosen one when it is plugged in,
    /// otherwise the main one. `fellBack` says the choice was abandoned.
    static func resolve(preferred: String, connected: [String], main: String?) -> (uuid: String?, fellBack: Bool) {
        if !preferred.isEmpty {
            if connected.contains(preferred) { return (preferred, false) }
            return (main ?? connected.first, true)
        }
        return (main ?? connected.first, false)
    }

    /// After the displays settle: keep the capture as it is, or rebuild it.
    ///
    /// - The display it is on is gone: rebuild on whatever now holds it.
    /// - It fell back to the main display and the chosen one is back: go
    ///   home. This is the ONLY reason to leave a capture that works.
    /// - Its display changed size: rebuild, the frame was sized for the old one.
    /// - An app (not a window) is shared through a display filter, and its
    ///   windows may have moved when a display came or went: rebuild whenever
    ///   the set of displays changed.
    static func decide(capture: Capture, connected: [Display], displaySetChanged: Bool, main: String?) -> Decision {
        guard let active = capture.activeUUID else { return .keep }
        guard let now = connected.first(where: { $0.uuid == active }) else {
            let target = resolve(preferred: capture.preferredUUID, connected: connected.map(\.uuid), main: main)
            return .rebuild(target.uuid == nil
                ? "the screen being shared was unplugged and no display is left to capture"
                : "the screen being shared was unplugged; capturing \(target.fellBack ? "the main display" : "your chosen display") instead")
        }
        if capture.fellBack, !capture.preferredUUID.isEmpty,
           connected.contains(where: { $0.uuid == capture.preferredUUID }) {
            return .rebuild("your chosen display is back; returning to it")
        }
        if let was = capture.activePixelSize, was != now.pixelSize {
            return .rebuild("the shared display changed size (\(Int(was.width))\u{00D7}\(Int(was.height)) to \(Int(now.pixelSize.width))\u{00D7}\(Int(now.pixelSize.height)))")
        }
        if !capture.isWholeDisplay, displaySetChanged {
            return .rebuild("the displays changed, so the shared app may have moved; looking for it again")
        }
        return .keep
    }
}

enum WindowRescue {

    /// Where a window should be, or nil when it is fine where it is.
    ///
    /// Fine means: a useful part of it is on some screen's visible area, and
    /// its top edge (the part you grab) is reachable. Otherwise it goes onto
    /// the screen it overlaps most - or `preferred`, or the first screen when
    /// it overlaps none - shrunk to fit and moved inside that screen's visible
    /// frame. Frames are in AppKit's global space; `visible` are the screens'
    /// visible frames.
    static func rescuedFrame(for frame: CGRect, visible: [CGRect], preferred: CGRect? = nil) -> CGRect? {
        guard !visible.isEmpty, frame.width > 0, frame.height > 0 else { return nil }
        let area = frame.width * frame.height
        var best: (rect: CGRect, overlap: CGFloat)?
        for rect in visible {
            let hit = frame.intersection(rect)
            let overlap = hit.isNull ? 0 : hit.width * hit.height
            if best == nil || overlap > best!.overlap { best = (rect, overlap) }
        }
        let gripStrip = CGRect(x: frame.minX, y: frame.maxY - 30, width: frame.width, height: 30)
        let gripReachable = visible.contains { rect in
            let hit = gripStrip.intersection(rect)
            return !hit.isNull && hit.width >= 40 && hit.height >= 10
        }
        if let best, best.overlap >= 0.25 * area, gripReachable { return nil }

        let target = (best?.overlap ?? 0) > 0 ? best!.rect : (preferred ?? visible[0])
        let width = min(frame.width, target.width), height = min(frame.height, target.height)
        // Nowhere near any screen (its own display is gone): centre it. Part
        // way off one: slide it back in.
        let lost = (best?.overlap ?? 0) == 0
        let x = lost ? target.midX - width / 2 : min(max(frame.minX, target.minX), target.maxX - width)
        let y = lost ? target.midY - height / 2 : min(max(frame.minY, target.minY), target.maxY - height)
        let moved = CGRect(x: x.rounded(), y: y.rounded(), width: width.rounded(), height: height.rounded())
        return moved == frame ? nil : moved
    }
}
