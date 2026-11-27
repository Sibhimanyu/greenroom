//
//  MeetingSetupLibrary.swift
//  Greenroom
//
//  Where the Meeting setup meets the layout library (docs/specs/meeting-setup.md P3): the three
//  values a layout brings in, writing the module's saved values back into the active layout, and
//  what any change to the library means for the setup (a layout switch, or an edit in Settings ->
//  Layouts). Pure; compiled by the test target as it is.
//
import Foundation

extension LayoutTemplate {
    /// The three saved values of this layout. A layout that saves no camera state, camera piece or
    /// share resolves it to `fallback` (the app's own values, as before there were layouts).
    func setupValues(fallback: MeetingSetup.Values) -> MeetingSetup.Values {
        MeetingSetup.Values(cameraState: cameraState ?? fallback.cameraState,
                            cameraPiece: camera ?? fallback.cameraPiece,
                            share: share ?? fallback.share)
    }
}

extension LayoutLibrary {
    /// Writes the named settings of `values` into the active layout, only. False with no active
    /// layout or nothing to write.
    @discardableResult
    mutating func writeActive(_ values: MeetingSetup.Values, settings: Set<MeetingSetup.Setting>) -> Bool {
        guard !settings.isEmpty, var t = active else { return false }
        if settings.contains(.cameraState) { t.cameraState = values.cameraState }
        if settings.contains(.cameraPiece) { t.camera = values.cameraPiece }
        if settings.contains(.share) { t.share = values.share }
        update(t)
        return true
    }
}

extension LayoutCamera {
    /// The Home or bubble drag's box, taken onto this piece: only the numbers of the shape that was
    /// dragged change (Cutout's two, or the bubble's three), clamped to the ranges the bubble allows.
    /// The shape stays. Nothing else comes from the box, so a drag never saves a working copy (R6.2).
    func placing(_ box: PresenceBox) -> LayoutCamera {
        func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double { min(max(v, r.lowerBound), r.upperBound) }
        var next = self
        if box.isCutout {
            next.cutoutHeightFraction = clamp(box.cutoutHeightFraction, PresenceGeometry.cutoutHeights)
            next.cutoutRightInset = clamp(box.cutoutRightInset, 0...0.95)
        } else {
            next.widthFraction = clamp(box.widthFraction, PresenceGeometry.widthFractions)
            next.rightInset = clamp(box.rightInset, PresenceGeometry.insets)
            next.bottomInset = clamp(box.bottomInset, PresenceGeometry.insets)
        }
        return next
    }
}

extension MeetingSetup {
    /// The library changed (a pick, an edit in Settings -> Layouts, Restore original, an undo, an
    /// import). A different active layout is a layout switch (R5.1, R5.2, R5.4). The same layout with
    /// different saved values is a Layouts edit for each setting that differs (R4.2). With no active
    /// layout the setup stands on its own values.
    ///
    /// The library already holds what it holds, so the returned effect's `saved` is always empty:
    /// only `inUse` says what the Stage needs.
    @discardableResult
    mutating func followLibrary(oldActiveID: UUID?, library: LayoutLibrary, fallback: Values, meetingLive: Bool) -> Effect {
        guard let active = library.active else { return Effect() }
        let values = active.setupValues(fallback: fallback)
        var effect: Effect
        if active.id != oldActiveID {
            effect = apply(.layoutSwitched(to: values))
        } else {
            effect = Effect()
            func edit(_ change: Change) {
                let one = savedEdit(change, meetingLive: meetingLive)
                effect.inUse.formUnion(one.inUse)
            }
            if values.cameraState != saved.cameraState { edit(.cameraState(values.cameraState)) }
            if values.cameraPiece != saved.cameraPiece { edit(.cameraPiece(values.cameraPiece)) }
            if values.share != saved.share { edit(.share(values.share)) }
        }
        effect.saved = []
        return effect
    }
}
