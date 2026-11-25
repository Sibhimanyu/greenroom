//
//  LayoutEditHistory.swift
//  Greenroom
//
//  Pure rules of undo in the Layouts editor: what to call an edit ("Move Chat"),
//  which edits fold into one step, and what an undo puts back. The page keeps
//  the UndoManager; this only decides.
//
import Foundation

enum LayoutEditHistory {
    struct Step: Equatable {
        var name: String
        /// Edits with the same key, close together in time, are one undo step.
        var coalesceKey: String?
    }

    static func describe(from old: LayoutLibrary, to new: LayoutLibrary,
                         pieceName: (LayoutPiece) -> String) -> Step? {
        if new.templates.count > old.templates.count { return Step(name: "Add Layout", coalesceKey: nil) }
        if new.templates.count < old.templates.count { return Step(name: "Delete Layout", coalesceKey: nil) }
        guard let i = old.templates.indices.first(where: { old.templates[$0] != new.templates[$0] }) else { return nil }
        if old.templates[i].name != new.templates[i].name {
            return Step(name: "Rename Layout", coalesceKey: "name:\(new.templates[i].id)")
        }
        if (old.templates[i].twoDisplays == nil) != (new.templates[i].twoDisplays == nil) {
            return Step(name: new.templates[i].twoDisplays == nil ? "Remove Second Display" : "Add Second Display",
                        coalesceKey: nil)
        }
        if old.templates[i].camera != new.templates[i].camera {
            let was = old.templates[i].camera ?? LayoutCamera(), now = new.templates[i].camera ?? LayoutCamera()
            let what = was.shape != now.shape ? "Change Camera Shape"
                : (was.widthFraction != now.widthFraction || was.cutoutHeightFraction != now.cutoutHeightFraction
                   ? "Resize Camera" : "Move Camera")
            return Step(name: what, coalesceKey: nil)
        }
        let before = placed(old.templates[i]), after = placed(new.templates[i])
        for (id, now) in after {
            guard let was = before[id] else { return Step(name: "Add \(pieceName(now.piece))", coalesceKey: nil) }
            if was.slot != now.slot {
                let where_ = now.slot == .second ? "Second" : "Main"
                return Step(name: "Move \(pieceName(now.piece)) to \(where_) Display", coalesceKey: nil)
            }
            if was.piece.rect != now.piece.rect {
                let resized = was.piece.rect.w != now.piece.rect.w || was.piece.rect.h != now.piece.rect.h
                return Step(name: "\(resized ? "Resize" : "Move") \(pieceName(now.piece))", coalesceKey: nil)
            }
        }
        for (id, now) in after {
            if let was = before[id], was.piece.showsToEveryone != now.piece.showsToEveryone {
                let name = pieceName(now.piece)
                return Step(name: now.piece.showsToEveryone ? "Show \(name) to Everyone" : "Hide \(name) from Everyone",
                            coalesceKey: nil)
            }
        }
        for (id, now) in after {
            if let was = before[id], Visibility.onMyScreen(piece: was.piece) != Visibility.onMyScreen(piece: now.piece) {
                let name = pieceName(now.piece)
                return Step(name: Visibility.onMyScreen(piece: now.piece).isOn ? "Show \(name) on My Screen"
                                                                               : "Hide \(name) on My Screen",
                            coalesceKey: nil)
            }
        }
        for (id, now) in after {
            if let was = before[id], was.piece != now.piece {
                return Step(name: "Change \(pieceName(now.piece))", coalesceKey: "settings:\(id)")
            }
        }
        for (id, was) in before where after[id] == nil {
            return Step(name: "Remove \(pieceName(was.piece))", coalesceKey: nil)
        }
        return Step(name: "Change Layout", coalesceKey: nil)
    }

    private typealias Placed = (slot: LayoutSlot, piece: LayoutPiece)

    /// Every piece of a layout by id, with the display it is on.
    private static func placed(_ t: LayoutTemplate) -> [UUID: Placed] {
        var all: [UUID: Placed] = [:]
        for slot in [LayoutSlot.one, .main, .second] {
            for piece in t.pieces(for: slot) { all[piece.id] = (slot, piece) }
        }
        return all
    }

    /// Typing makes a stream of edits; they are one step while they keep coming.
    static func folds(previous: (key: String, at: Date)?, into step: Step, at now: Date) -> Bool {
        guard let previous, let key = step.coalesceKey, previous.key == key else { return false }
        return now.timeIntervalSince(previous.at) <= foldWindow
    }

    /// The library after an undo (or redo): `target` is the snapshot to go back to,
    /// `from` the one being left, `current` what is there now.
    static func restoring(_ target: LayoutLibrary, undoing from: LayoutLibrary, onto current: LayoutLibrary) -> LayoutLibrary {
        var result = target
        // A step that did not choose a layout leaves the choice alone, if it still exists.
        if target.activeID == from.activeID, let keep = current.activeID, target.template(id: keep) != nil {
            result.activeID = keep
        }
        return result
    }

    static let foldWindow: TimeInterval = 1.2
}
