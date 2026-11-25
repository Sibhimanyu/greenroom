//
//  LayoutEditorRules.swift
//  Greenroom
//
//  Pure rules of the Layouts editor's chrome (Direction A): which menu holds
//  which action, which control shows on which canvas, what the inspector shows
//  for a selection, and whether the ghost "+ Second display" canvas is there.
//  The views only draw what this says, so the rules are tested without a window.
//
import Foundation

enum LayoutEditorRules {

    // MARK: The layout's ⋯ menu

    enum LayoutAction: Hashable {
        case rename, duplicate, restoreOriginal, delete
    }

    /// The ⋯ menu beside the layout name. Restore original only for a built-in
    /// layout that can be restored; Delete is always last.
    static func layoutMenu(isBuiltIn: Bool, canRestore: Bool) -> [LayoutAction] {
        var items: [LayoutAction] = [.rename, .duplicate]
        if isBuiltIn && canRestore { items.append(.restoreOriginal) }
        items.append(.delete)
        return items
    }

    // MARK: The second display

    /// The ghost "+ Second display" canvas: only while the layout has no
    /// two-display version.
    static func showsGhostSecondCanvas(hasTwoDisplays: Bool) -> Bool { !hasTwoDisplays }

    enum SecondChoice: Hashable {
        case automatic
        case display(String)
        /// A saved display that is unplugged stays visible and valid.
        case savedNotConnected(String)
        case remove
    }

    /// The "Second ▾" menu on the second canvas's header: the display picker
    /// (Automatic, each connected non-main display, the saved one if it is
    /// away), then Remove two-display version.
    static func secondMenu(connectedNonMainIDs: [String], savedUUID: String) -> [SecondChoice] {
        var items: [SecondChoice] = [.automatic] + connectedNonMainIDs.map { SecondChoice.display($0) }
        if !savedUUID.isEmpty, !connectedNonMainIDs.contains(savedUUID) {
            items.append(.savedNotConnected(savedUUID))
        }
        items.append(.remove)
        return items
    }

    // MARK: The shared canvas

    /// The canvas that carries the "Everyone sees this" tag, the Preview switch
    /// and Show on screen: the one-display canvas, or the shared display's.
    static func carriesSharedControls(slot: LayoutSlot, template: LayoutTemplate) -> Bool {
        switch slot {
        case .one: return true // the one-display canvas is always the shared one
        case .main, .second:
            return template.twoDisplays != nil && slot == template.effectiveSharedSlot
        }
    }

    /// The rows inside "Everyone sees this ▾", in order. The display choice only
    /// exists with a two-display version; the window picker and the slide-show
    /// switch only for One window.
    enum SharedRow: Hashable {
        case sharedDisplay, whatsShared, windowApp, followSlideShow
    }

    static func sharedMenu(hasTwoDisplays: Bool, kind: ShareTarget.Kind) -> [SharedRow] {
        var rows: [SharedRow] = []
        if hasTwoDisplays { rows.append(.sharedDisplay) }
        rows.append(.whatsShared)
        if kind == .window { rows += [.windowApp, .followSlideShow] }
        return rows
    }

    // MARK: Where "+" is allowed to add

    /// Every canvas has its own +; it adds to that canvas's display. On a
    /// version with two displays the slot is the canvas's own, never the last
    /// one clicked.
    static func addSlot(canvas: LayoutSlot) -> LayoutSlot { canvas }

    // MARK: The inspector

    enum Inspector: Equatable {
        case empty
        case camera
        case piece(UUID)
    }

    /// What the inspector shows. `selection` is a piece id, the camera's id or
    /// nil; an id that is no longer in the layout is the empty state.
    static func inspector(selection: UUID?, cameraID: UUID, hasCamera: Bool, pieceIDs: Set<UUID>) -> Inspector {
        guard let selection else { return .empty }
        if selection == cameraID { return hasCamera ? .camera : .empty }
        return pieceIDs.contains(selection) ? .piece(selection) : .empty
    }

    /// Nothing selected: the inspector carries the layout's description sentence
    /// (the separate caption is gone while a layout is open).
    static func inspectorShowsDescription(_ inspector: Inspector) -> Bool { inspector == .empty }

    /// The caption under the cards only while no editor is open (None).
    static func captionUnderCards(hasActiveLayout: Bool) -> Bool { !hasActiveLayout }

    // MARK: Keys, as help text

    /// What the old hint row said, now the canvas's tooltip.
    static func keyboardHelp(twoDisplays: Bool) -> String {
        "Select a piece, then arrows move it, \u{21E7}-arrows resize it, \u{232B} removes it"
            + (twoDisplays ? ", \u{2325}\u{2190} \u{2325}\u{2192} sends it to the other display." : ".")
    }

    // MARK: Controls at rest (for the count in the plan)

    /// Show on screen needs something to show.
    static func canShowOnScreen(pieceCount: Int) -> Bool { pieceCount > 0 }

    /// Apply now only while a meeting runs another layout.
    static func offersApplyNow(liveLayoutID: UUID?, templateID: UUID) -> Bool {
        liveLayoutID != nil && liveLayoutID != templateID
    }
}
