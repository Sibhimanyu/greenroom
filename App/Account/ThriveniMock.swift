//
//  ThriveniMock.swift
//  Greenroom
//
//  Made-up Thriveni data for the dummy sign-in flow. Replaced by the real API
//  client when it exists.
//
import Foundation

enum ThriveniMock {
    struct Assignment: Identifiable, Hashable {
        let id: String
        let course: String
        let title: String
        let due: Date

        var label: String { "\(course): \(title)" }
    }

    static let assignments: [Assignment] = {
        let day: TimeInterval = 86_400
        let now = Date()
        return [
            Assignment(id: "a1", course: "Class 9 Science", title: "Lab demonstration recording", due: now.addingTimeInterval(3 * day)),
            Assignment(id: "a2", course: "Class 10 Mathematics", title: "Worked solutions, chapter 4", due: now.addingTimeInterval(6 * day)),
            Assignment(id: "a3", course: "Class 8 English", title: "Recitation practice", due: now.addingTimeInterval(9 * day)),
            Assignment(id: "a4", course: "Class 10 Physics", title: "Optics walkthrough", due: now.addingTimeInterval(14 * day)),
        ]
    }()

    /// Pretends to post `link` to `assignment`. Always succeeds.
    static func post(link: String, to assignment: Assignment, note: String = "") async throws {
        try await Task.sleep(nanoseconds: 1_000_000_000)
    }
}
