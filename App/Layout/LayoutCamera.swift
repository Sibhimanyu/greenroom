//
//  LayoutCamera.swift
//  Greenroom
//
//  The camera piece a layout saves: its spot, size and shape (Square, Rounded,
//  Circle, Cutout, Presenter). The camera LOOK (background, removal, mirror)
//  stays global. A layout also saves What's shared; that is `ShareTarget`.
//  Both are optional on `LayoutTemplate`: old files, and layouts made since,
//  have none and use the global settings (the app's working copy).
//
//  Pure, and compiled by the test target as it is.
//
import Foundation

extension WebcamShape: Codable {}

struct LayoutCamera: Codable, Equatable {
    var shape: WebcamShape = .circle
    // The shipped defaults (StageLayout), so an old file reads as today's app.
    var widthFraction = 0.24
    var rightInset = 0.045
    var bottomInset = 0.06
    var cutoutHeightFraction = 0.5
    var cutoutRightInset = 0.02

    init() {}

    init(shape: WebcamShape, box: PresenceBox) {
        self.shape = shape
        widthFraction = box.widthFraction
        rightInset = box.rightInset
        bottomInset = box.bottomInset
        cutoutHeightFraction = box.cutoutHeightFraction
        cutoutRightInset = box.cutoutRightInset
    }

    private enum CodingKeys: String, CodingKey {
        case shape, widthFraction, rightInset, bottomInset, cutoutHeightFraction, cutoutRightInset
    }

    /// Every key is optional: a missing or unreadable one keeps today's default.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let raw = try? c.decodeIfPresent(String.self, forKey: .shape), let s = WebcamShape(rawValue: raw) { shape = s }
        func number(_ key: CodingKeys, _ fallback: Double) -> Double {
            (try? c.decodeIfPresent(Double.self, forKey: key)) ?? fallback
        }
        widthFraction = number(.widthFraction, widthFraction)
        rightInset = number(.rightInset, rightInset)
        bottomInset = number(.bottomInset, bottomInset)
        cutoutHeightFraction = number(.cutoutHeightFraction, cutoutHeightFraction)
        cutoutRightInset = number(.cutoutRightInset, cutoutRightInset)
    }

    var box: PresenceBox {
        PresenceBox(widthFraction: widthFraction, rightInset: rightInset, bottomInset: bottomInset,
                    cutoutHeightFraction: cutoutHeightFraction, cutoutRightInset: cutoutRightInset,
                    isCutout: shape == .cutout)
    }

    /// Today's global camera settings, straight from the defaults the app has always written.
    static func global(from defaults: UserDefaults) -> LayoutCamera {
        var c = LayoutCamera()
        c.shape = WebcamShape(rawValue: defaults.string(forKey: "webcamShape") ?? "") ?? c.shape
        func number(_ key: String, _ fallback: Double) -> Double { (defaults.object(forKey: key) as? Double) ?? fallback }
        c.widthFraction = number("bubbleWidthFraction", c.widthFraction)
        c.rightInset = number("bubbleRightInset", c.rightInset)
        c.bottomInset = number("bubbleBottomInset", c.bottomInset)
        c.cutoutHeightFraction = number("cutoutHeightFraction", c.cutoutHeightFraction)
        c.cutoutRightInset = number("cutoutRightInset", c.cutoutRightInset)
        return c
    }

    /// Today's global share target. One app is no longer offered; it reads as the whole screen.
    static func globalShare(from defaults: UserDefaults) -> ShareTarget {
        var s = defaults.data(forKey: "shareTarget").flatMap { try? JSONDecoder().decode(ShareTarget.self, from: $0) } ?? ShareTarget()
        if s.kind == .app { s.kind = .display }
        return s
    }
}

extension LayoutTemplate {
    /// The layout's camera piece, or `fallback` (the global settings) when it has none.
    func resolvedCamera(fallback: LayoutCamera) -> LayoutCamera { camera ?? fallback }
    /// What the layout shares, or `fallback` when it has none.
    func resolvedShare(fallback: ShareTarget) -> ShareTarget { share ?? fallback }
}

extension LayoutLibrary {
    static let cameraMigratedKey = "layoutCameraMigrated"
    static let shareMigratedKey = "layoutShareMigrated"

    /// One time each: copy today's global camera and share target into every layout, so day
    /// one looks the same. The key is set once the copy is done; later edits and later globals
    /// are never copied again. Returns whether anything changed.
    @discardableResult
    mutating func migrateCameraAndShare(camera: LayoutCamera, share: ShareTarget, defaults: UserDefaults) -> Bool {
        var changed = false
        if !defaults.bool(forKey: Self.cameraMigratedKey) {
            for i in templates.indices { templates[i].camera = camera }
            defaults.set(true, forKey: Self.cameraMigratedKey)
            changed = true
        }
        if !defaults.bool(forKey: Self.shareMigratedKey) {
            for i in templates.indices { templates[i].share = share }
            defaults.set(true, forKey: Self.shareMigratedKey)
            changed = true
        }
        return changed
    }
}

/// When the layout's camera and share are put into the live settings. The live settings
/// (Home, the bar, a drag in the meeting) are a working copy: they change the running meeting
/// and are never written back to the layout. They are replaced only at these moments.
enum LayoutPieceAdoption {
    struct Plan: Equatable {
        var camera: LayoutCamera?
        var share: ShareTarget?
    }

    /// Start, Stop and launch: the layout's value applies. Nil with no layout (the globals stand).
    static func atStart(_ template: LayoutTemplate?) -> Plan? {
        guard let template, template.camera != nil || template.share != nil else { return nil }
        return Plan(camera: template.camera, share: template.share)
    }

    /// The library changed. A different layout brings its pieces in; the same one brings in
    /// only the piece that was edited. Anything else leaves the live settings alone.
    static func plan(old: LayoutTemplate?, new: LayoutTemplate?) -> Plan? {
        guard let new else { return nil }
        guard let old, old.id == new.id else { return atStart(new) }
        let plan = Plan(camera: new.camera != old.camera ? new.camera : nil,
                        share: new.share != old.share ? new.share : nil)
        return plan.camera == nil && plan.share == nil ? nil : plan
    }
}
