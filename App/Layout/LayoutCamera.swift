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

    /// Where the camera sits, in words ("bottom right"), for a layout's description. The insets are
    /// fractions from the right and bottom edges; a spot past the middle is on the other side.
    var cornerPhrase: String {
        let side = rightInset + widthFraction / 2 > 0.5 ? "left" : "right"
        let vertical = bottomInset > 0.5 ? "top" : "bottom"
        return "\(vertical) \(side)"
    }

    var box: PresenceBox {
        PresenceBox(widthFraction: widthFraction, rightInset: rightInset, bottomInset: bottomInset,
                    cutoutHeightFraction: cutoutHeightFraction, cutoutRightInset: cutoutRightInset,
                    isCutout: shape == .cutout)
    }

    /// The defaults keys the app's working copy of the camera piece lives under, in one place:
    /// `global(from:)` reads them and the coordinator's adoption keeps them out of its way.
    enum Key {
        static let shape = "webcamShape"
        static let width = "bubbleWidthFraction"
        static let rightInset = "bubbleRightInset"
        static let bottomInset = "bubbleBottomInset"
        static let cutoutHeight = "cutoutHeightFraction"
        static let cutoutRightInset = "cutoutRightInset"
    }
    static let defaultsKeys = [Key.shape, Key.width, Key.rightInset, Key.bottomInset, Key.cutoutHeight, Key.cutoutRightInset]
    static let shareDefaultsKey = "shareTarget"

    /// Today's global camera settings, straight from the defaults the app has always written.
    static func global(from defaults: UserDefaults) -> LayoutCamera {
        var c = LayoutCamera()
        c.shape = WebcamShape(rawValue: defaults.string(forKey: Key.shape) ?? "") ?? c.shape
        func number(_ key: String, _ fallback: Double) -> Double { (defaults.object(forKey: key) as? Double) ?? fallback }
        c.widthFraction = number(Key.width, c.widthFraction)
        c.rightInset = number(Key.rightInset, c.rightInset)
        c.bottomInset = number(Key.bottomInset, c.bottomInset)
        c.cutoutHeightFraction = number(Key.cutoutHeight, c.cutoutHeightFraction)
        c.cutoutRightInset = number(Key.cutoutRightInset, c.cutoutRightInset)
        return c
    }

    /// Today's global share target. One app is no longer offered; it reads as the whole screen.
    static func globalShare(from defaults: UserDefaults) -> ShareTarget {
        var s = defaults.data(forKey: shareDefaultsKey).flatMap { try? JSONDecoder().decode(ShareTarget.self, from: $0) } ?? ShareTarget()
        if s.kind == .app { s.kind = .display }
        return s
    }
}

extension LayoutLibrary {
    static let cameraMigratedKey = "layoutCameraMigrated"
    static let shareMigratedKey = "layoutShareMigrated"

    /// One time each: copy today's global camera and share target into every layout, so day
    /// one looks the same. A key is set only after `save` has worked, so a failed save runs
    /// the copy again next launch; later edits and later globals are never copied again.
    /// Returns whether anything changed and was saved.
    @discardableResult
    mutating func migrateCameraAndShare(camera: LayoutCamera, share: ShareTarget, defaults: UserDefaults,
                                        save: (LayoutLibrary) -> Bool) -> Bool {
        var keys: [String] = []
        if !defaults.bool(forKey: Self.cameraMigratedKey) {
            for i in templates.indices { templates[i].camera = camera }
            keys.append(Self.cameraMigratedKey)
        }
        if !defaults.bool(forKey: Self.shareMigratedKey) {
            for i in templates.indices { templates[i].share = share }
            keys.append(Self.shareMigratedKey)
        }
        guard !keys.isEmpty else { return false }
        guard save(self) else { return false }
        for key in keys { defaults.set(true, forKey: key) }
        return true
    }
}

/// The camera look in the camera piece's inspector (R11). The look is one setting for every
/// layout; the shape, size and spot beside it are per layout.
enum CameraLookRules {
    static let sameInEveryLayout = "Same in every layout"

    /// Normal / Blur / Image are for the bubble shapes. Cutout and Presenter take the background away themselves.
    static func showsBackground(shape: WebcamShape) -> Bool { !shape.usesChromaKey }
    static func showsRemoval(shape: WebcamShape) -> Bool { shape.usesChromaKey }

    /// The folded group's one line, so a closed group still says what is set.
    static func summary(shape: WebcamShape, backgroundName: String, removal: BackgroundRemoval, mirror: Bool) -> String {
        let first = showsRemoval(shape: shape)
            ? (removal == .automatic ? "Automatic removal" : "Green screen")
            : backgroundName
        return "\(first) \u{00B7} \(mirror ? "Mirror on" : "Mirror off")"
    }
}

/// Who is changing the camera piece or what is shared. Only the Layouts tab (and the Webcam
/// tab, gone in P8) write the saved layout; everything else changes the running meeting.
enum LayoutEditSource: Equatable, CaseIterable {
    case settingsLayouts, home, bar, meeting

    var writesSavedLayout: Bool { self == .settingsLayouts }
}

extension LayoutLibrary {
    /// Writes the camera piece and/or share into the active layout only. False with no active layout.
    @discardableResult
    mutating func updateActive(camera: LayoutCamera?, share: ShareTarget?) -> Bool {
        guard var t = active else { return false }
        if let camera { t.camera = camera }
        if let share { t.share = share }
        update(t)
        return true
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
    /// A share the owner chose on Home before Start (`keepingLiveShare`) stays for that meeting.
    static func atStart(_ template: LayoutTemplate?, keepingLiveShare: Bool = false) -> Plan? {
        guard let template else { return nil }
        let share = keepingLiveShare ? nil : template.share
        guard template.camera != nil || share != nil else { return nil }
        return Plan(camera: template.camera, share: share)
    }

    /// Snap Back: the layout's share returns; the camera spot is left as the meeting has it.
    static func atSnapBack(_ template: LayoutTemplate?) -> Plan? {
        guard let share = template?.share else { return nil }
        return Plan(camera: nil, share: share)
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
