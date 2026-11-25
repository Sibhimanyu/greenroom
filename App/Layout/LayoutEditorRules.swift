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

/// Where a piece's caption goes when the camera sits over the piece.
enum LayoutCaptionRules {
    /// The largest strip of `tile` (above, below, left or right of the covered part) that the
    /// camera does not cover, so the caption and the camera's own label never draw over each
    /// other. The whole tile when nothing is covered.
    static func freeRegion(tile: CGRect, covered: CGRect?) -> CGRect {
        guard let covered, covered.intersects(tile) else { return tile }
        let c = covered.intersection(tile)
        let strips = [
            CGRect(x: tile.minX, y: tile.minY, width: tile.width, height: c.minY - tile.minY),
            CGRect(x: tile.minX, y: c.maxY, width: tile.width, height: tile.maxY - c.maxY),
            CGRect(x: tile.minX, y: tile.minY, width: c.minX - tile.minX, height: tile.height),
            CGRect(x: c.maxX, y: tile.minY, width: tile.maxX - c.maxX, height: tile.height),
        ]
        return strips.filter { $0.width > 0 && $0.height > 0 }.max { $0.width * $0.height < $1.width * $1.height } ?? tile
    }
}

enum LayoutEditorRules {

    // MARK: The layout's ⋯ menu

    enum LayoutAction: Hashable {
        case rename, duplicate, restoreOriginal, delete
    }

    /// The ⋯ menu beside the layout name. Restore original only for a built-in
    /// layout that can be restored (`LayoutLibrary.canRestore`); Delete is last, and absent for
    /// Leave my windows alone (`LayoutLibrary.canDelete`: there is always one active layout).
    static func layoutMenu(isBuiltIn: Bool, canRestore: Bool, canDelete: Bool = true) -> [LayoutAction] {
        var items: [LayoutAction] = [.rename, .duplicate]
        if isBuiltIn && canRestore { items.append(.restoreOriginal) }
        if canDelete { items.append(.delete) }
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
    }

    /// The "Second ▾" menu on the second canvas's header: the display picker
    /// (Automatic, each connected non-main display, the saved one if it is
    /// away). Remove two-display version is a button the view adds under it.
    static func secondMenu(connectedNonMainIDs: [String], savedUUID: String) -> [SecondChoice] {
        var items: [SecondChoice] = [.automatic] + connectedNonMainIDs.map { SecondChoice.display($0) }
        if !savedUUID.isEmpty, !connectedNonMainIDs.contains(savedUUID) {
            items.append(.savedNotConnected(savedUUID))
        }
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

    /// The caption under the cards only while no editor is open (None).
    static func captionUnderCards(hasActiveLayout: Bool) -> Bool { !hasActiveLayout }

    // MARK: Right-click on a piece

    enum PieceAction: Hashable {
        case moveToOtherDisplay(toSecond: Bool)
        case showToEveryone, hideFromEveryone
        case showOnMyScreen, hideOnMyScreen
        case remove
    }

    /// The rows of a piece's right-click menu, in order. A switch the rule has settled
    /// (the Greenroom Browser is always shown to everyone; the Chat is always on your screen)
    /// is not offered. Remove is always last.
    static func pieceMenu(piece: LayoutPiece, target: Visibility.Target, slot: LayoutSlot,
                          hasOtherDisplay: Bool) -> [PieceAction] {
        var items: [PieceAction] = []
        if hasOtherDisplay { items.append(.moveToOtherDisplay(toSecond: slot != .second)) }
        let everyone = Visibility.everyoneSees(piece: piece, target: target)
        if !everyone.isFixed { items.append(everyone.isOn ? .hideFromEveryone : .showToEveryone) }
        let mine = Visibility.onMyScreen(piece: piece)
        if !mine.isFixed { items.append(mine.isOn ? .hideOnMyScreen : .showOnMyScreen) }
        items.append(.remove)
        return items
    }

    // MARK: A Meeting window that fills its display

    /// The piece after a hand edit puts it at `rect`. A Meeting window that fills its display is
    /// then an ordinary piece at that rect (`fillsDisplay` off); a rect that did not change
    /// leaves it as it was. One change, so undo restores the rect and the fill together.
    static func adjusting(_ piece: LayoutPiece, to rect: UnitRect) -> LayoutPiece {
        guard rect != piece.rect else { return piece }
        var p = piece
        p.rect = rect
        if case let .meeting(true, hidden) = p.kind { p.kind = .meeting(fillsDisplay: false, startsHidden: hidden) }
        return p
    }

    /// The "Fill this display" switch. On takes the whole display; off keeps the rect it has.
    static func settingFill(_ piece: LayoutPiece, on: Bool) -> LayoutPiece {
        guard case let .meeting(_, hidden) = piece.kind else { return piece }
        var p = piece
        p.kind = .meeting(fillsDisplay: on, startsHidden: hidden)
        if on { p.rect = .full }
        return p
    }

    /// The switch's hint. The people gallery follows a filled display, so say what off does.
    static func fillHint(othersOnDisplay: Bool) -> String {
        othersOnDisplay
            ? "Remove the other pieces on this display first."
            : "The whole display shows the meeting and the people in it. Off, this is an ordinary piece and the people gallery no longer opens on this display."
    }

    // MARK: Which pieces answer the pointer and the keyboard

    /// Whether a piece on the canvas can be selected, dragged, resized, right-clicked and moved
    /// by key. On My screen always: the fade on a piece the meeting does not see is only a look,
    /// and a display that is not connected yet is still set up by hand. Preview: Everyone is the
    /// read-only picture of what the meeting sees, so nothing in it is edited there.
    static func piecesAreInteractive(previewEveryone: Bool, everyoneSees: Bool, displayConnected: Bool) -> Bool {
        !previewEveryone
    }

    // MARK: The live camera picture

    /// R11.3: the camera is opened for the picture only while someone looks at it.
    static func runsCameraPreview(cameraSelected: Bool, previewEveryone: Bool, tabShown: Bool) -> Bool {
        tabShown && (cameraSelected || previewEveryone)
    }

    // MARK: After an undo or redo

    /// The editor's own state: which version is shown, which canvas is active, what is selected.
    struct EditorState: Equatable {
        var showsTwo: Bool
        var activeSlot: LayoutSlot
        var selection: UUID?
    }

    /// The editor state made true to the library: an undo or redo can add or remove the
    /// two-display version or a piece, and the state must not point at what is no longer there.
    static func reconciled(_ state: EditorState, in template: LayoutTemplate?, cameraID: UUID) -> EditorState {
        var next = state
        guard let template else { return EditorState(showsTwo: false, activeSlot: .one, selection: nil) }
        next.showsTwo = state.showsTwo && template.twoDisplays != nil
        if !next.showsTwo { next.activeSlot = .one } else if next.activeSlot == .one { next.activeSlot = .main }
        if let id = state.selection, id != cameraID, !template.placedPieces.contains(where: { $0.piece.id == id }) {
            next.selection = nil
        }
        return next
    }

    // MARK: What VoiceOver says

    /// "Chat, 3 of 12 columns, Everyone sees this". One eye says who sees it; a dashed piece also says it starts hidden.
    static func spokenPiece(name: String, columns: Int, everyone: Bool, onMyScreen: Bool) -> String {
        var words = "\(name), \(columns) of \(LayoutGeometry.divisions) columns, "
            + VisibilitySymbol.everyoneSees(everyone).words
        if !onMyScreen { words += ", " + VisibilitySymbol.startsHidden.words }
        return words
    }

    /// What dragging the camera does, said from the camera state (never a fixed "moves for everyone").
    static func cameraMoveNote(everyoneSees: Bool, onMyScreen: Bool) -> String {
        switch (everyoneSees, onMyScreen) {
        case (true, true): return "It moves for everyone."
        case (true, false): return "It moves for everyone, but is hidden on your screen."
        case (false, true): return "Only you see it, so it does not move for everyone."
        case (false, false): return "The camera is off, so nobody sees it."
        }
    }

    /// VoiceOver's "Show or hide for everyone" and "on my screen": only where the badge is a switch
    /// under the current share, the same filter as the right-click menu.
    static func offersEveryoneAction(piece: LayoutPiece, target: Visibility.Target) -> Bool {
        !Visibility.everyoneSees(piece: piece, target: target).isFixed
    }

    static func offersMyScreenAction(piece: LayoutPiece) -> Bool {
        !Visibility.onMyScreen(piece: piece).isFixed
    }

    /// "Main display, everyone sees this".
    static func spokenCanvas(name: String, isShared: Bool) -> String {
        isShared ? "\(name), everyone sees this" : name
    }

    /// The words on a menu row. Another app's eye means where it opens.
    static func title(for action: PieceAction, isApp: Bool) -> String {
        switch action {
        case let .moveToOtherDisplay(toSecond): return toSecond ? "Move to second display" : "Move to main display"
        case .showToEveryone: return "Show to everyone"
        case .hideFromEveryone: return "Hide from everyone"
        case .showOnMyScreen: return isApp ? "Open on my screen" : "Starts on my screen"
        case .hideOnMyScreen: return isApp ? "Open minimised" : "Starts hidden on my screen"
        case .remove: return "Remove"
        }
    }

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
