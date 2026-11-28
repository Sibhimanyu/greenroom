import Foundation

/// Features the owner has shelved: the code stays, the way to use it does not
/// ship. See docs/specs/shelved.md. Foundation-only so the test target can
/// compile it.
enum Shelved {
    /// "Record the Mac's own sound", shelved 2026-11-27. True only in Debug,
    /// where the controls stay (marked shelved) so it can still be tested.
    /// False in Release: no control, and the effective value is always off.
    static let macSound: Bool = {
        #if DEBUG
        true
        #else
        false
        #endif
    }()

    /// The caption added to the controls in a Debug build.
    static let macSoundCaption = "(shelved, needs testing)"

    /// What the recorder and the screen capture use: the stored switch, but
    /// never on while the feature is shelved. `macSoundAvailable` is passed
    /// in so the rule is testable; callers use `Shelved.macSound`.
    static func effectiveMacSound(stored: Bool, macSoundAvailable: Bool) -> Bool {
        stored && macSoundAvailable
    }
}
