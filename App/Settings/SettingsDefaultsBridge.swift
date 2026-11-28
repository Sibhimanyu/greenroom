//
//  SettingsDefaultsBridge.swift
//  Greenroom
//
//  The settings that live only in UserDefaults (no published property on the
//  coordinator): the meeting window's choices, the invite-copy and notes toggles,
//  the camera mirror and recorder visibility. Reads them into a SettingsTransfer
//  and applies a SettingsTransfer back. The defaults are injected so a test never
//  touches the real ones. docs/specs/settings-transfer.md R5.
//
import Foundation

struct SettingsDefaultsBridge {
    var defaults: UserDefaults = .standard

    /// Fills the fields this bridge owns with this Mac's effective values (the
    /// default where nothing is saved), so a file says what the exporter sees,
    /// not just what it has changed.
    func read(into transfer: inout SettingsTransfer) {
        transfer.copyInviteOnStart = SavedSettings.copyInviteOnStart.load(from: defaults)
        transfer.sessionNotesEnabled = SavedSettings.sessionNotesEnabled.load(from: defaults)
        transfer.mirrorSelfView = CameraLook.load(from: defaults).mirror
        transfer.meetingViewsEnabled = SavedSettings.meetingViewsEnabled.load(from: defaults)
        let prefs = MeetingViewPrefs(defaults: defaults)
        transfer.meetingWindowView = prefs.view.rawValue
        transfer.meetingWindowShareLayout = prefs.shareLayout.rawValue
        transfer.meetingWindowShareSplit = prefs.splitFraction
        transfer.meetingWindowHideSelfView = prefs.hideSelfView
        transfer.meetingWindowHideVideoOff = prefs.hideNoVideo
    }

    /// Writes the fields the file carries; the rest stay as this Mac has them.
    /// Values are expected to have been through `SettingsImportRules.sanitized`.
    func apply(_ transfer: SettingsTransfer) {
        if let v = transfer.copyInviteOnStart { SavedSettings.copyInviteOnStart.save(v, to: defaults) }
        if let v = transfer.sessionNotesEnabled { SavedSettings.sessionNotesEnabled.save(v, to: defaults) }
        if let v = transfer.mirrorSelfView { defaults.set(v, forKey: CameraLook.mirrorKey) }   // the Look's key; the coordinator re-reads the Look after an import
        if let v = transfer.meetingViewsEnabled { SavedSettings.meetingViewsEnabled.save(v, to: defaults) }
        let prefs = MeetingViewPrefs(defaults: defaults)
        if let raw = transfer.meetingWindowView, let v = MeetingViewMode(rawValue: raw) { prefs.view = v }
        if let raw = transfer.meetingWindowShareLayout, let v = MeetingShareLayout(rawValue: raw) { prefs.shareLayout = v }
        if let v = transfer.meetingWindowShareSplit { prefs.splitFraction = v }
        if let v = transfer.meetingWindowHideSelfView { prefs.hideSelfView = v }
        if let v = transfer.meetingWindowHideVideoOff { prefs.hideNoVideo = v }
    }
}
