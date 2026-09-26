//
//  ScreenroomAvailability.swift
//  Greenroom
//
//  The one switch that holds Screenroom out of a release.
//
//  Same shape as CuesAvailability, and for the same reason: a feature that is
//  being built in the open still ships in every build made from main, so the
//  gate has to exist before the first release that contains the code, not
//  after someone finds it. Screenroom is further from ready than Cues was - it has
//  a window and a note box and nothing that reads them back - so it is held
//  behind one constant every entry point checks.
//
//  Unlike Cues there is no stored preference to fight: nothing has ever
//  written a Screenroom default to UserDefaults, so hiding the doors really does
//  hide the feature. The constant still earns its place by naming the doors
//  in one file, so shipping is a one-line change and the list of things to
//  check is not spread across the app.
//
//    - ContentView's toolbar row   (the Screenroom button)
//    - MenuBarView                 (Open Screenroom)
//    - the "marks" Window scene    (refuses to build its contents)
//
//    - Sessions' Analysis and Notes tabs, and the scrubber's marks
//
//  Settings → Screenroom is not behind it and never was.
//
//  Shipped: `isReleased` is true. Setting it back to false hides the doors
//  above again.
//
import SwiftUI

enum ScreenroomAvailability {

    /// True since Screenroom shipped. See the file note.
    static let isReleased = true
}
