//
//  UpdateGate.swift
//  Greenroom
//
//  Never during a class.
//
//  Setting SUScheduledCheckInterval on its own decides how OFTEN Sparkle
//  looks for a new version. It says nothing about WHEN, and when is the part
//  that matters here: the interval elapsing while a teacher is mid-lesson
//  puts an update dialog on a screen that is being shared with thirty
//  students, over the top of whatever they were being shown.
//
//  That is the whole job of this file. A scheduled check is refused while a
//  session is live, and the next one comes round on its own once the class
//  ends - Sparkle keeps its own schedule and does not need to be told to try
//  again.
//
//  A check the teacher ASKED for is always allowed, even mid-class. Pressing
//  "Check for Updates..." is a decision, and an app that ignores a menu item
//  it is still showing is worse than one that interrupts. Sparkle only offers
//  in any case; nothing installs without "Install and Relaunch" being
//  pressed, so the worst outcome of allowing it is a dialog somebody went
//  looking for.
//
import Foundation
import Sparkle

final class UpdateGate: NSObject, SPUUpdaterDelegate {

    /// One, and it outlives everything.
    ///
    /// Sparkle holds its delegate WEAKLY. A gate created inline in the
    /// updater's initializer would be released before the first scheduled
    /// check, the delegate would read back nil, and every check would be
    /// allowed - the failure being silent and only visible mid-class, months
    /// later, as a dialog on a shared screen.
    static let shared = UpdateGate()

    /// Refuses a check Sparkle started by itself; allows one a person asked
    /// for.
    ///
    /// Thrown rather than returned - the Objective-C method hands back a BOOL
    /// and an NSError, and Sparkle's Swift interface turns that pair into
    /// `throws`. The message is not shown to anybody; it goes to Sparkle's
    /// log, which is where somebody wondering why no update appeared during
    /// period four would look.
    nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck != .updates else { return }   // the teacher pressed it
        let live = MainActor.assumeIsolated {
            guard let coordinator = CoordinatorController.shared else { return false }
            return coordinator.isRunning || coordinator.virtualCamActive || coordinator.isRecording
        }
        guard live else { return }
        throw NSError(domain: "Greenroom", code: 30, userInfo: [
            NSLocalizedDescriptionKey: "A class is running. Greenroom does not check for updates during a session \u{2014} the dialog would land on a shared screen."
        ])
    }
}
