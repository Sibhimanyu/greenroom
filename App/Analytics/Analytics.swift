//
//  Analytics.swift
//  Greenroom
//
//  What Greenroom tells Zoho Apptics, and - more importantly - what it never
//  tells it.
//
//  The status log was the obvious thing to forward, and forwarding it would have
//  been a serious mistake. Those 81 log statements interpolate live values:
//  `entry.name` (a student, usually a child), `meetingNumber`, `preset.name`,
//  recording paths that carry the account name, and raw
//  `error.localizedDescription`. Shipping that text would put class rosters and
//  meeting IDs on a server, from an app whose whole claim is that the class stays
//  on this Mac.
//
//  So nothing here sends a message. Each log line is classified into one of a
//  small fixed set of events and described with non-identifying properties:
//  counts, coarse durations, enum codes, booleans. Someone reading the dashboard
//  can see that a session ran about forty minutes, that eleven control actions
//  were used and two were refused by Zoom. They cannot learn who was in the room
//  or which meeting it was.
//
//  Two questions the dashboard is meant to answer, both as counts: which
//  features get used (`feature_used`, broken down by `feature`) and which
//  settings people switch on or off (`setting_changed`, by `setting` + `state`).
//  Neither carries what was typed, opened, or who was there.
//
//  Free-plan shape, measured rather than assumed (Apptics pricing, Aug 2026):
//    - 50,000 "engagements" a month, shared across events, screens, tracked API
//      calls AND remote-logger lines. A class produces well under a hundred
//      events, so a heavy month lands near 6,000. Comfortable.
//    - 5,000 "errors" a month, covering handled and unhandled together. Only
//      genuine failures go through `failure(_:)`, never routine refusals.
//    - 100 distinct event-PROPERTY names per app, for the app's whole lifetime.
//      That is the cap worth respecting: property keys live in `Key` below and
//      nowhere else, so the vocabulary stays countable. Adding keys ad hoc at
//      call sites is how an app silently reaches 101 and starts dropping them.
//    - 25 key-value pairs per single event, enforced inside the SDK.
//    - 30-day retention, so this is for spotting trends, not an audit trail.
//
import Foundation
// APEvent lives in AppticsEventTracker, not the Apptics umbrella; the kill
// switch (setCompleteOff) lives in Apptics. Both modules are needed.
import Apptics
import AppticsEventTracker

@MainActor
enum Analytics {

    /// The complete event vocabulary. Apptics caps distinct event names nowhere,
    /// but a small set keeps the dashboard readable and the properties
    /// consistent between events.
    enum Event: String {
        case sessionStart   = "session_start"
        case sessionEnd     = "session_end"
        case surfaceShown   = "surface_shown"
        case controlAction  = "control_action"
        case recordingStart = "recording_start"
        case recordingEnd   = "recording_end"
        case quickHide      = "quick_hide"
        case failure        = "failure"
        /// One press of one feature: a clip, Snap Back, a preset, a chat
        /// message, find-in-page. Counted, never described.
        case featureUsed    = "feature_used"
        /// A setting flipped in Settings - the state it was flipped TO, as an
        /// enum code, so the dashboard shows what is on and what is off across
        /// installs. Suppressed while a settings file is imported, which would
        /// otherwise read as twenty deliberate changes.
        case settingChanged = "setting_changed"
    }

    /// Every property key the app may ever send. Deliberately exhaustive and
    /// deliberately short - see the 100-key note above.
    enum Key: String {
        case mode                          // "start" | "join"
        case customUI      = "custom_ui"
        case displays                      // how many screens were attached
        case durationBand = "duration_band"
        case endedBy      = "ended_by"
        case surface                       // "speaker" | "participants" | "chat"
        case placement                     // "reference_display" | "main_window"
        case action                        // which control was used
        case refused                       // Zoom would not allow it
        case roster                        // how many people were in the room
        case spaceBand    = "space_band"
        case code                          // failure code
        case state                         // "on" | "off", or an enum code
        case feature                       // which feature was used (fixed codes)
        case setting                       // which setting changed (fixed codes)
        case source                        // clip source: "recording" | "buffer"
        case mainApp      = "main_app"     // "builtin_browser" | "chrome" | "other_browser" | "other_app"
    }

    /// True while `importSettings` assigns every field at once.
    static var suppressSettingEvents = false

    private static let group = "greenroom"

    /// Coarse buckets, never raw values.
    ///
    /// An exact session length is a weak identifier: it correlates with a
    /// timetable, and a timetable identifies a class. A band still answers "are
    /// lessons running long?" without carrying that.
    static func band(seconds: TimeInterval) -> String {
        switch seconds {
        case ..<60: return "under_1m"
        case ..<600: return "1_10m"
        case ..<1800: return "10_30m"
        case ..<3600: return "30_60m"
        default: return "over_60m"
        }
    }

    static func band(gigabytes: Double) -> String {
        switch gigabytes {
        case ..<4: return "critical"
        case ..<12: return "low"
        case ..<50: return "ok"
        default: return "plenty"
        }
    }

    /// Sends an event, or does nothing at all when analytics were never wired
    /// up. The Info.plist key is written by the Apptics pre-build script only
    /// when apptics-config.plist exists, so this is the same honest signal
    /// `AppDelegate.startAnalytics()` uses.
    static func track(_ event: Event, _ properties: [Key: String] = [:]) {
        guard isConfigured else { return }
        // Mapped to a plain dictionary only here, at the boundary, so no caller
        // can reach past the Key enum and invent a property name.
        let payload = Dictionary(uniqueKeysWithValues: properties.map { ($0.key.rawValue, $0.value) })
        APEvent.trackEvent(event.rawValue, andGroupName: group, withProperties: payload)
    }

    /// One use of a feature. `name` is a fixed code from the call site
    /// (`clip_2`, `snap_back`, `chat_send`), never anything typed by a person.
    static func feature(_ name: String, source: String? = nil) {
        var properties: [Key: String] = [.feature: name]
        if let source { properties[.source] = source }
        track(.featureUsed, properties)
    }

    /// A setting changed to `state`. Booleans arrive as "on"/"off"; enums as
    /// their raw code. Nothing that can carry an identifier is ever a setting
    /// event: no URLs, no display UUIDs, no bundle IDs - `mainAppKind` maps
    /// the chosen app to one of four buckets first.
    static func setting(_ name: String, _ state: String) {
        guard !suppressSettingEvents else { return }
        track(.settingChanged, [.setting: name, .state: state])
    }

    static func setting(_ name: String, on: Bool) {
        setting(name, on ? "on" : "off")
    }

    /// The main app as a bucket, never as its bundle ID.
    static func mainAppKind(bundleID: String) -> String {
        if AppCatalog.isBuiltInBrowser(bundleID) { return "builtin_browser" }
        if bundleID == ChromeWindowManager.chromeBundleID { return "chrome" }
        if AppCatalog.isBrowser(bundleID) { return "other_browser" }
        return "other_app"
    }

    /// A genuine failure, billed against the free plan's 5,000 errors a month.
    ///
    /// Takes a stable code, never an `Error`. `localizedDescription` is written
    /// for a person reading a status line and routinely contains paths, meeting
    /// numbers and server text - exactly what must not leave the Mac.
    static func failure(_ code: String) {
        track(.failure, [.code: code])
    }

    private static var isConfigured: Bool {
        Bundle.main.object(forInfoDictionaryKey: "AP_INFOPLIST_FILE") != nil
    }

    /// The user's own off switch, honoured on every future launch.
    ///
    /// `setCompleteOff` is the real one: Apptics documents that it suppresses
    /// every network call including device registration, rather than merely
    /// pausing event delivery.
    static func setEnabled(_ enabled: Bool) {
        guard isConfigured else { return }
        Apptics.setCompleteOff(!enabled)
    }
}
