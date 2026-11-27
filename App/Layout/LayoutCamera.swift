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

    /// The default for what the owner makes new (R43): the Rounded shape, at the shipped spot and size.
    /// `init()` and decoding keep Circle, so a saved layout with no shape is not changed.
    static var rounded: LayoutCamera {
        var c = LayoutCamera()
        c.shape = .roundedRectangle
        return c
    }

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
            // Only layouts with no camera of their own: a built-in added since (P9) keeps the one it ships with.
            for i in templates.indices where templates[i].camera == nil { templates[i].camera = camera }
            keys.append(Self.cameraMigratedKey)
        }
        if !defaults.bool(forKey: Self.shareMigratedKey) {
            for i in templates.indices where templates[i].share == nil { templates[i].share = share }
            keys.append(Self.shareMigratedKey)
        }
        guard !keys.isEmpty else { return false }
        guard save(self) else { return false }
        for key in keys { defaults.set(true, forKey: key) }
        return true
    }
}

extension LayoutLibrary {
    static let cameraStateMigratedKey = "layoutCameraStateMigrated"

    /// meeting-setup R1.2, one time: every layout with no camera state gets the one saved for the
    /// whole app (`saved`, from the two old keys; the keys stay readable). A built-in that ships with
    /// one (Everyone & me) keeps it, like `migrateCameraAndShare`. The key is set only after `save`
    /// worked, so a failed save runs again next launch. Returns whether it ran and saved.
    @discardableResult
    mutating func migrateCameraState(saved: CameraState, defaults: UserDefaults, save: (LayoutLibrary) -> Bool) -> Bool {
        guard !defaults.bool(forKey: Self.cameraStateMigratedKey) else { return false }
        for i in templates.indices where templates[i].cameraState == nil { templates[i].cameraState = saved }
        guard save(self) else { return false }
        defaults.set(true, forKey: Self.cameraStateMigratedKey)
        return true
    }
}

/// The camera look in the camera piece's inspector (R11). The look is one setting for every
/// layout; the shape, size and spot beside it are per layout.
enum CameraLookRules {
    static let sameInEveryLayout = "Same in every layout"

    /// Mirror my camera (R11.4): the toggle flips the owner's camera bubble on their screen, like a
    /// mirror, in every layout and in Only me. The meeting's picture (Stage) and Greenroom's
    /// recordings are never flipped. Other apps' screen recordings may show the flipped bubble.
    static func mirrorsBubble(mirror: Bool) -> Bool { mirror }
    static let mirrorTitle = "Mirror my camera"
    static let mirrorHelp = "Flips your camera on your screen only. The meeting and Greenroom\u{2019}s recordings always see you the right way round."
    static let stageMirrors = false
    static let recordingsMirror = false

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

/// A place the camera can be put with one tap.
enum PlacementSpot: Hashable {
    case topLeft, topRight, bottomLeft, bottom, bottomRight
    var isRight: Bool { self == .topRight || self == .bottomRight }
    var isBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    var label: String {
        switch self {
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottom: return "Bottom centre"
        case .bottomRight: return "Bottom right"
        }
    }
    /// Where the dot sits on the little screen, 0...1.
    var point: CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: 0, y: 0)
        case .topRight: return CGPoint(x: 1, y: 0)
        case .bottomLeft: return CGPoint(x: 0, y: 1)
        case .bottom: return CGPoint(x: 0.5, y: 1)
        case .bottomRight: return CGPoint(x: 1, y: 1)
        }
    }
}

/// The corner picker and Reset in the camera piece's inspector (R11): the
/// Webcam tab's quick controls, now on the layout's saved camera. Pure.
enum CameraPlacementRules {
    /// A camera is 16:9 until the shape crops it square.
    private static let cameraAspect = 16.0 / 9.0

    /// Presenter rebuilds the whole scene rather than placing a source: nothing to size or place.
    static func isAdjustable(shape: WebcamShape) -> Bool { shape != .presenterLarge }

    static func spots(for shape: WebcamShape) -> [PlacementSpot] {
        shape == .cutout ? [.bottomLeft, .bottom, .bottomRight] : [.topLeft, .topRight, .bottomLeft, .bottomRight]
    }

    /// The camera put at a spot, with the margins a fresh install uses. `canvasAspect` is the
    /// canvas's width over height.
    static func placing(_ camera: LayoutCamera, at spot: PlacementSpot, canvasAspect: Double) -> LayoutCamera {
        let shipped = LayoutCamera()
        var next = camera
        if camera.shape == .cutout {
            let width = camera.cutoutHeightFraction * cameraAspect / canvasAspect   // a share of the canvas width
            switch spot {
            case .bottomLeft: next.cutoutRightInset = 1 - width - shipped.cutoutRightInset
            case .bottom: next.cutoutRightInset = (1 - width) / 2
            default: next.cutoutRightInset = shipped.cutoutRightInset
            }
            next.cutoutRightInset = max(0, next.cutoutRightInset)
        } else {
            let aspect = camera.shape.cropsToSquare ? 1 : cameraAspect
            let height = camera.widthFraction * canvasAspect / aspect                // a share of the canvas height
            next.rightInset = spot.isRight ? shipped.rightInset : 1 - camera.widthFraction - shipped.rightInset
            next.bottomInset = spot.isBottom ? shipped.bottomInset : 1 - height - shipped.bottomInset
            next.rightInset = max(0, next.rightInset)
            next.bottomInset = max(0, next.bottomInset)
        }
        return next
    }

    /// The spot the camera is on, or nil when it has been dragged in between.
    static func currentSpot(of camera: LayoutCamera, canvasAspect: Double) -> PlacementSpot? {
        spots(for: camera.shape).first { spot in
            let goal = placing(camera, at: spot, canvasAspect: canvasAspect)
            return camera.shape == .cutout
                ? abs(goal.cutoutRightInset - camera.cutoutRightInset) < 0.01
                : abs(goal.rightInset - camera.rightInset) < 0.01 && abs(goal.bottomInset - camera.bottomInset) < 0.01
        }
    }

    /// Is the size and spot of the shape on screen still where the app shipped it?
    static func isAtDefault(_ camera: LayoutCamera) -> Bool { reset(camera) == camera }

    /// Back to the shipped size and spot of the shape on screen. The shape is kept; so are the
    /// numbers of the shapes not on screen.
    static func reset(_ camera: LayoutCamera) -> LayoutCamera {
        let shipped = LayoutCamera()
        var next = camera
        if camera.shape == .cutout {
            next.cutoutHeightFraction = shipped.cutoutHeightFraction
            next.cutoutRightInset = shipped.cutoutRightInset
        } else {
            next.widthFraction = shipped.widthFraction
            next.rightInset = shipped.rightInset
            next.bottomInset = shipped.bottomInset
        }
        return next
    }
}

/// Who is committing a camera drag. Only Settings -> Layouts writes the saved layout; Home's
/// preview (like the bar and the meeting, which never commit through here) changes the running meeting.
enum LayoutEditSource: Equatable, CaseIterable {
    case settingsLayouts, home

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
extension LayoutTemplate {
    /// R32.2: the layout a running meeting becomes when its saved layout is edited.
    /// The pieces, camera and share follow the edit; the shared display stays as the meeting started it until
    /// "Apply now" (which takes the whole saved layout).
    func adoptingEdit(_ edited: LayoutTemplate) -> LayoutTemplate {
        var adopted = edited
        if adopted.twoDisplays != nil { adopted.twoDisplays?.sharedSlot = twoDisplays?.sharedSlot ?? .main }
        return adopted
    }
}

enum LayoutPieceAdoption {
    struct Plan: Equatable {
        var camera: LayoutCamera?
        var share: ShareTarget?

        /// Adopting a camera or a share changes the working copy only; the compositor behind Home's
        /// live preview and the bubble must be told too, or they keep the old picture until Start.
        var refreshesPicture: Bool { camera != nil || share != nil }
    }

    /// The library changed (an edit in Settings -> Layouts, a pick). With no meeting running, the
    /// active layout's changed pieces flow into the working copy at once; an edit to another layout
    /// touches nothing. In a meeting only the running layout's camera moves; its share waits for
    /// Start, Snap Back or Apply now.
    static func forLibraryEdit(old: LayoutLibrary, new: LayoutLibrary, locked: Bool, running: LayoutTemplate?) -> Plan? {
        if locked {
            guard let running, let edited = new.template(id: running.id) else { return nil }
            return plan(old: running, new: edited).map { Plan(camera: $0.camera, share: nil) }
        }
        return plan(old: old.active, new: new.active)
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
