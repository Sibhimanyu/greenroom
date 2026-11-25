//
//  SettingsTransfer.swift
//  Greenroom
//
//  The settings file: what Settings -> Transfer exports and imports.
//  Foundation-only on purpose, so GreenroomTests compiles it.
//
import Foundation

// One exported file = a new machine fully configured, instead of hand-typing
// five credential strings across two Settings tabs. The Zoom credentials are
// app-level, deliberately shareable with a trusted teammate (see
// Vendor/README.md) - and because the chat feature only works in meetings
// hosted under the credential-owning account anyway, the teammate importing
// this file gets working chat in exactly the meetings this app starts.
//
// The exported JSON contains the secrets in PLAINTEXT - hand it over
// directly (AirDrop etc.) and delete it after importing.

/// Every field optional so a partial or older file imports cleanly,
/// touching only what it contains.
struct SettingsTransfer: Codable, Equatable {
    var sdkClientID: String?
    var sdkClientSecret: String?
    var s2sAccountID: String?
    var s2sClientID: String?
    var s2sClientSecret: String?
    var webcamShape: String?
    var backgroundRemoval: String?
    // Import-only: files exported before the layout creator carry these. They are
    // decoded and folded into "Your previous layout"; nothing writes them now.
    var mainAppBundleID: String?
    var mainAppURL: String?
    var mainAppOnStart: Bool?
    var browserRestoresTabs: Bool?
    var browserSearchSuggestions: Bool?
    var browserClosesOnStop: Bool?
    // These five keep the old spelling on purpose. They are not internal
    // names: SettingsTransfer is Codable with no CodingKeys, so each property
    // name IS a key in the settings file the teacher exports. Renaming them
    // would make every file exported before the feature became "Cues" fail to
    // import its Cues settings, and pinning them with CodingKeys would mean
    // listing all forty-odd properties of this struct by hand.
    var prompterEnabled: Bool?
    var prompterVideoSearch: Bool?
    var prompterUseModel: Bool?
    var prompterSaveTranscript: Bool?
    var prompterLocaleIdentifier: String?
    var youtubeUploadMode: String?
    var youtubePrivacy: String?
    var youtubeClientID: String?
    var youtubeClientSecret: String?
    var peopleViewOnStart: Bool?
    var peopleViewDisplayUUID: String?
    var screenCaptureDisplayUUID: String?
    var shareTarget: ShareTarget?
    var hideSelfView: Bool?
    /// Import-only (older files); see CoordinatorController.speakerTileShortcutEnabled.
    var speakerTileShortcutEnabled: Bool?
    var autoRecordOnStart: Bool?
    /// Added with phase 4 of the Recorditor port.
    var recordingCountdownSeconds: Int?
    var recordSystemAudio: Bool?
    var meetingPresets: [MeetingPreset]?
    /// Import-only (older files): decoded and folded into "Your previous layout".
    var workspaceLayout: WorkspaceLayout?
    /// The layout library (templates and the Start choice). Added with the layout
    /// creator. Import REPLACES this Mac's library with it. A file without one
    /// carries only workspaceLayout / chromeLayout, which import migrates into a
    /// template appended to the library.
    var layoutLibrary: LayoutLibrary?
    /// Settings -> Shortcuts: only what differs from the defaults. A file without
    /// it leaves this Mac's shortcuts alone.
    var shortcutBindings: ShortcutBindings?

    // Added 2026-09-19, after an audit found fourteen real settings that a
    // teacher had set and an export did not carry. A colleague importing the
    // file got a Mac configured most of the way and no sign of which part was
    // missing, which is the worst shape a transfer can take.
    var userDisplayName: String?
    var customUIMode: Bool?
    var clipBufferEnabled: Bool?
    var participantPanelOnMainDisplay: Bool?
    /// Carried whole, including the camera identifiers. They mean nothing on
    /// another Mac, and that is handled where it matters rather than here -
    /// CameraDirectorSettings.availableOnly drops any camera that is not
    /// plugged in, so an imported config degrades to off instead of cutting
    /// to a device that does not exist.
    var cameraDirector: CameraDirectorSettings?
    /// Where the webcam sits in the composite. Dragged into place by hand,
    /// which makes it the most annoying thing in this list to redo.
    var bubbleWidthFraction: Double?
    var bubbleRightInset: Double?
    var bubbleBottomInset: Double?
    var cutoutHeightFraction: Double?
    var cutoutRightInset: Double?
    var cuesUseWhisper: Bool?
    /// The agent command, as JSON. Portable: it is a command line, and the
    /// Mac that imports it either has that CLI or does not.
    var screenroomAgent: String?
    /// The teacher's rubric, as JSON. Authored content - the one thing here
    /// nobody could reconstruct from memory.
    var screenroomRubric: String?
    /// The transcription LANGUAGE only. The model path is deliberately left
    /// behind: it is an absolute path to a file on the Mac that exported it,
    /// and importing it would point a colleague's Greenroom at a model they
    /// do not have. The receiving Mac picks its own best model.
    var screenroomLanguage: String?
    // Added with settings-transfer D1 (docs/specs/settings-transfer.md): settings
    // an export did not carry. All optional, so older files still import and
    // older builds ignore them.
    /// "Normal", "Blur" or "Image". Import turns Image into Blur when the
    /// picture it points at is a file this Mac does not have.
    var cameraBackground: String?
    /// A preset's name, or `custom-<stamp>` (the setting travels, the file does not).
    var cameraBackgroundImage: String?
    var className: String?
    /// "create", "join" or "record".
    var meetingMode: String?
    /// The microphone's uniqueID. Applied only if it is connected to this Mac.
    var micDeviceUID: String?
    var copyInviteOnStart: Bool?
    var sessionNotesEnabled: Bool?
    var mirrorSelfView: Bool?
    var visibleToRecorders: Bool?
    var meetingWindowView: String?
    var meetingWindowShareLayout: String?
    var meetingWindowShareSplit: Double?
    var meetingWindowHideSelfView: Bool?
    var meetingWindowHideVideoOff: Bool?
    var meetingViewsEnabled: Bool?
    // Legacy fields from Chrome-only-era exports - still imported, never
    // written anymore (same as the layout keys above: import-only).
    var chromeLayout: String?
    var chromeURL: String?
    var chromeOnStart: Bool?
}
