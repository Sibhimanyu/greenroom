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
        transfer.copyInviteOnStart = bool(SettingsKeys.copyInviteOnStart, default: true)
        transfer.sessionNotesEnabled = bool(SettingsKeys.sessionNotesEnabled, default: false)
        transfer.mirrorSelfView = bool(SettingsKeys.mirrorSelfView, default: true)
        transfer.visibleToRecorders = PresenceRecorderRules.visibleToRecorders(
            stored: defaults.object(forKey: SettingsKeys.visibleToRecorders) as? Bool)
        transfer.meetingViewsEnabled = bool(SettingsKeys.meetingViewsEnabled, default: true)
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
        if let v = transfer.copyInviteOnStart { defaults.set(v, forKey: SettingsKeys.copyInviteOnStart) }
        if let v = transfer.sessionNotesEnabled { defaults.set(v, forKey: SettingsKeys.sessionNotesEnabled) }
        if let v = transfer.mirrorSelfView { defaults.set(v, forKey: SettingsKeys.mirrorSelfView) }
        if let v = transfer.visibleToRecorders { defaults.set(v, forKey: SettingsKeys.visibleToRecorders) }
        if let v = transfer.meetingViewsEnabled { defaults.set(v, forKey: SettingsKeys.meetingViewsEnabled) }
        let prefs = MeetingViewPrefs(defaults: defaults)
        if let raw = transfer.meetingWindowView, let v = MeetingViewMode(rawValue: raw) { prefs.view = v }
        if let raw = transfer.meetingWindowShareLayout, let v = MeetingShareLayout(rawValue: raw) { prefs.shareLayout = v }
        if let v = transfer.meetingWindowShareSplit { prefs.splitFraction = v }
        if let v = transfer.meetingWindowHideSelfView { prefs.hideSelfView = v }
        if let v = transfer.meetingWindowHideVideoOff { prefs.hideNoVideo = v }
    }

    private func bool(_ key: String, default fallback: Bool) -> Bool {
        (defaults.object(forKey: key) as? Bool) ?? fallback
    }
}
