import Foundation

/// A saved Join Existing shortcut: a friendly name plus the meeting
/// number (stored as bare digits) and passcode. Codable so it persists
/// and rides the settings-transfer file.
struct MeetingPreset: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var number: String
    var password: String

    init(id: UUID = UUID(), name: String, number: String, password: String) {
        self.id = id
        self.name = name
        self.number = number
        self.password = password
    }

    /// How the preset reads in a menu. Saving with the name left blank
    /// falls the name back to the meeting number, and the old
    /// "name - number" format then rendered that twice
    /// ("78904918702 - 78904918702"). Collapse it to the number alone.
    var menuLabel: String {
        name == number ? number : "\(name) \u{2014} \(number)"
    }
}
