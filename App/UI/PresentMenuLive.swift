//
//  PresentMenuLive.swift
//  Greenroom
//
//  The coordinator on one side and `PresentMenu` (pure, tested) on the other.
//  Every surface that offers Present (the control bar's Share cell, the
//  meeting window's Share button, the menu bar) calls `presentMenuEntries()`
//  when its menu opens, so the app and window lists are read then, not when the
//  surface was drawn.
//
//  Picking a target does what Home's SHARE chip does: set it, then ask the
//  compositor to rebuild (`requestShapeApply(rebuild: true)`), which applies
//  live.
//
import Foundation

extension CoordinatorController {

    /// The Present menu as it stands now: fresh app and window lists.
    func presentMenuEntries() -> [MenuEntry] {
        PresentMenu.entries(presentMenuState(), presentMenuActions())
    }

    func presentMenuState() -> PresentMenu.State {
        var s = PresentMenu.State()
        let target = shareTarget
        s.kind = PresentMenu.Kind(rawValue: target.kind.rawValue) ?? .display
        s.displayID = screenCaptureDisplayUUID
        s.displays = DisplayResolver.connectedDisplays().map { .init(id: $0.id, title: $0.label) }
        s.apps = ShareTarget.runningApps().map { .init(id: $0.bundleID, title: $0.name) }
        s.appBundleID = target.appBundleID
        var seen = Set<String>()
        s.windows = ShareTarget.windows().filter { seen.insert($0.key).inserted }.map { w in
            let base = w.title.isEmpty ? w.appName : "\(w.appName) \u{2013} \(w.title)"
            return .init(bundleID: w.bundleID, appName: w.appName, title: w.title,
                         label: base + w.placement.menuSuffix)
        }
        s.windowBundleID = target.appBundleID
        s.windowTitle = target.windowTitle
        s.cameraOff = cameraIsOff
        s.shapes = WebcamShape.allCases.map { .init(id: $0.rawValue, title: $0.label) }
        s.shapeID = webcamShape.rawValue
        s.layouts = layoutLibrary.templates.map { .init(id: $0.id.uuidString, title: $0.name) }
        s.liveLayoutID = liveSessionLayoutID?.uuidString
        s.layoutsAvailable = layoutToolsAvailable && liveSessionLayoutID != nil
        return s
    }

    func presentMenuActions() -> PresentMenu.Actions {
        var a = PresentMenu.Actions()
        a.pickKind = { [weak self] kind in
            guard let self, let k = ShareTarget.Kind(rawValue: kind.rawValue) else { return }
            self.shareTarget.kind = k
            self.requestShapeApply(rebuild: true)
        }
        a.pickDisplay = { [weak self] id in
            guard let self else { return }
            self.screenCaptureDisplayUUID = id
            self.shareTarget.kind = .display
            self.requestShapeApply(rebuild: true)
        }
        a.pickApp = { [weak self] app in
            guard let self else { return }
            self.shareTarget.kind = .app
            self.shareTarget.appBundleID = app.id
            self.shareTarget.appName = app.title
            self.shareTarget.windowTitle = ""
            self.requestShapeApply(rebuild: true)
        }
        a.pickWindow = { [weak self] w in
            guard let self else { return }
            self.shareTarget.kind = .window
            self.shareTarget.appBundleID = w.bundleID
            self.shareTarget.appName = w.appName
            self.shareTarget.windowTitle = w.title
            self.requestShapeApply(rebuild: true)
        }
        a.pickShape = { [weak self] id in
            guard let self, let shape = WebcamShape(rawValue: id) else { return }
            self.webcamShape = shape
            self.requestShapeApply()
        }
        a.pickLayout = { [weak self] id in
            guard let self, let uuid = UUID(uuidString: id) else { return }
            self.applyLayoutNow(uuid)
        }
        return a
    }
}
