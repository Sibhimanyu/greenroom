// Ported from Recorditor (ZRecorditor @7210322, native/MacRecorder/Support/TimeFormatting.swift).
import Foundation

enum TimeFormatting {

    /// "05:42" or "1:05:42"
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    /// "05:42.3" — used for the playhead readout.
    static func clockWithTenths(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00.0" }
        let total = Int(seconds)
        let tenths = Int((seconds - Double(total)) * 10)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d.%d", h, m, s, tenths)
        }
        return String(format: "%02d:%02d.%d", m, s, tenths)
    }

    /// "2m 49s" / "45s" — used for "removed" labels.
    static func spoken(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0s" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return "\(h)h \(m)m \(s)s"
        }
        if m > 0 {
            return "\(m)m \(s)s"
        }
        return "\(s)s"
    }
}
