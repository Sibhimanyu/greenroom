//
//  LayoutEditRecorder.swift
//  Greenroom
//
//  Puts the Layouts editor's edits on the Settings window's UndoManager, so
//  Cmd-Z, Shift-Cmd-Z and the Edit menu work. It watches the library the page
//  edits: every change is a snapshot before and after, which is the undoable
//  unit, so a new kind of edit needs nothing here. What to call a step, which
//  edits fold into one and what an undo puts back are LayoutEditHistory's.
//
import Foundation

@MainActor
final class LayoutEditRecorder {
    private var seen: LayoutLibrary
    private var last: (key: String, at: Date)?
    private let read: () -> LayoutLibrary
    private let write: (LayoutLibrary) -> Void
    private let nameOf: (LayoutPiece) -> String
    weak var undoManager: UndoManager?

    init(library: LayoutLibrary, read: @escaping () -> LayoutLibrary, write: @escaping (LayoutLibrary) -> Void,
         nameOf: @escaping (LayoutPiece) -> String) {
        seen = library
        self.read = read
        self.write = write
        self.nameOf = nameOf
    }

    /// The page saw the library change.
    func observe(_ new: LayoutLibrary, now: Date = Date()) {
        guard new != seen else { return }   // our own undo or redo coming back
        let old = seen
        seen = new
        guard let manager = undoManager, !manager.isUndoing, !manager.isRedoing,
              let step = LayoutEditHistory.describe(from: old, to: new, pieceName: nameOf) else { return }
        let folds = LayoutEditHistory.folds(previous: last, into: step, at: now)
        last = step.coalesceKey.map { ($0, now) }
        if folds { return }
        register(old, leaving: new, step.name, manager)
    }

    /// Drops this page's steps (the tab went away; they would write to a library no one shows).
    func forget() { undoManager?.removeAllActions(withTarget: self) }

    private func register(_ target: LayoutLibrary, leaving from: LayoutLibrary, _ name: String, _ manager: UndoManager) {
        manager.registerUndo(withTarget: self) { me in
            // Read what is there now: an edit that folded into this step moved it on.
            let current = me.read()
            let restored = LayoutEditHistory.restoring(target, undoing: from, onto: current)
            me.seen = restored
            me.last = nil
            me.write(restored)
            me.register(current, leaving: restored, name, manager)
        }
        manager.setActionName(name)
    }
}
