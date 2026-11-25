//
//  PreviewSecondDisplayRules.swift
//
//  The note Home's preview shows when the layout Start would use now has
//  pieces on a second display, which the picture (one display) cannot show.
//  Pure, so it is tested. The caller passes what `LayoutResolver.resolve`
//  decided, so the note and Start can never disagree.
//
import Foundation

enum PreviewSecondDisplayRules {

    /// `secondPieceIsMeeting`: one entry per piece placed on the second display
    /// (empty for the one-display version). Nil when nothing is on it.
    static func note(secondPieceIsMeeting: [Bool]) -> String? {
        guard !secondPieceIsMeeting.isEmpty else { return nil }
        let more = secondPieceIsMeeting.count - 1
        if secondPieceIsMeeting.contains(true) {
            return more == 0 ? "Meeting window on your second display"
                             : "Meeting window and \(more) more on your second display"
        }
        return secondPieceIsMeeting.count == 1 ? "1 window on your second display"
                                               : "\(secondPieceIsMeeting.count) windows on your second display"
    }

    /// From a resolution: what is on the second display.
    static func note(for result: LayoutResolver.Result) -> String? {
        note(secondPieceIsMeeting: result.placed.filter { $0.slot == .second }.map { $0.piece.kind.isMeeting })
    }

    /// The row under the picture: the note (if any) on the left, Show on
    /// screen on the right. Present whenever the layout places windows, since
    /// the button is always where you expect it; absent for a layout with no
    /// pieces (Show on screen has nothing to outline; the camera outline is
    /// not part of Home's action).
    struct Row: Equatable { var note: String? }

    /// The row for the active layout: none when it tiles no windows, that is no pieces, or a layout
    /// (Leave my windows alone) that moves none. The camera is not a piece and never counts.
    static func row(for template: LayoutTemplate?, secondPieceIsMeeting: [Bool]) -> Row? {
        guard let template, template.movesWindows else { return nil }
        return row(pieceCount: template.pieceCount, secondPieceIsMeeting: secondPieceIsMeeting)
    }

    static func row(pieceCount: Int?, secondPieceIsMeeting: [Bool]) -> Row? {
        guard (pieceCount ?? 0) > 0 else { return nil }
        return Row(note: note(secondPieceIsMeeting: secondPieceIsMeeting))
    }
}
