//
//  ZoomRESTAccess.swift
//  Greenroom
//
//  The one switch between the two ways Greenroom talks to Zoom's REST API:
//  as the person who signed in with Zoom, or with the Server-to-Server app
//  they pasted in (the advanced path, unchanged). The coordinator decides
//  which with `ZoomCredentialRules.restSource` and hands the result around;
//  nothing else needs to know which one it is holding.
//
import Foundation

@MainActor
enum ZoomRESTAccess {
    case signedIn(ZoomUserAuth)
    case ownApps(accountID: String, clientID: String, clientSecret: String)

    func startInstantMeeting(topic: String) async throws -> ZoomServerToServerClient.CreatedMeeting {
        switch self {
        case .signedIn(let user): return try await user.startInstantMeeting(topic: topic)
        case .ownApps(let a, let c, let s):
            return try await ZoomServerToServerClient.startInstantMeeting(topic: topic, accountID: a, clientID: c, clientSecret: s)
        }
    }

    func fetchZAK() async throws -> String {
        switch self {
        case .signedIn(let user): return try await user.zak()
        case .ownApps(let a, let c, let s):
            return try await ZoomServerToServerClient.fetchZAK(accountID: a, clientID: c, clientSecret: s)
        }
    }

    func listScheduledMeetings() async throws -> (meetings: [ZoomServerToServerClient.ScheduledMeeting], warning: String?) {
        switch self {
        case .signedIn(let user): return try await user.listMeetings()
        case .ownApps(let a, let c, let s):
            return try await ZoomServerToServerClient.listScheduledMeetings(accountID: a, clientID: c, clientSecret: s)
        }
    }

    /// The personal room (PMI) for the Scheduled list's pinned entry.
    func personalRoom() async -> ZoomPersonalRoom.Lookup {
        switch self {
        case .signedIn(let user): return await user.personalRoom()
        case .ownApps(let a, let c, let s):
            return await ZoomServerToServerClient.personalRoom(accountID: a, clientID: c, clientSecret: s)
        }
    }

    func createScheduledMeeting(_ spec: NewMeetingRequest) async throws -> ZoomServerToServerClient.CreatedScheduledMeeting {
        switch self {
        case .signedIn(let user): return try await user.createScheduledMeeting(spec)
        case .ownApps(let a, let c, let s):
            return try await ZoomServerToServerClient.createScheduledMeeting(spec, accountID: a, clientID: c, clientSecret: s)
        }
    }

    func meetingDetails(id: Int64) async throws -> [String: Any] {
        switch self {
        case .signedIn(let user): return try await user.meetingDetails(id: id)
        case .ownApps(let a, let c, let s):
            return try await ZoomServerToServerClient.meetingDetails(id: id, accountID: a, clientID: c, clientSecret: s)
        }
    }

    func updateScheduledMeeting(id: Int64, _ spec: NewMeetingRequest) async throws {
        switch self {
        case .signedIn(let user): try await user.updateScheduledMeeting(id: id, spec)
        case .ownApps(let a, let c, let s):
            try await ZoomServerToServerClient.updateScheduledMeeting(id: id, spec, accountID: a, clientID: c, clientSecret: s)
        }
    }

    func deleteScheduledMeeting(id: Int64) async throws {
        switch self {
        case .signedIn(let user): try await user.deleteScheduledMeeting(id: id)
        case .ownApps(let a, let c, let s):
            try await ZoomServerToServerClient.deleteScheduledMeeting(id: id, accountID: a, clientID: c, clientSecret: s)
        }
    }

    func liveMeetings() async -> [Int64] {
        switch self {
        case .signedIn(let user): return await user.liveMeetings()
        case .ownApps(let a, let c, let s):
            return await ZoomServerToServerClient.liveMeetings(accountID: a, clientID: c, clientSecret: s)
        }
    }

    func endMeetingReporting(id: Int64) async -> (ok: Bool, status: Int, code: Int?, detail: String) {
        switch self {
        case .signedIn(let user): return await user.endMeeting(id: id)
        case .ownApps(let a, let c, let s):
            return await ZoomServerToServerClient.endMeetingReporting(id: id, accountID: a, clientID: c, clientSecret: s)
        }
    }

    /// Silent warm-up ahead of Start.
    func warm() async {
        switch self {
        case .signedIn(let user): _ = try? await user.accessToken()
        case .ownApps(let a, let c, let s):
            await ZoomServerToServerClient.warmToken(accountID: a, clientID: c, clientSecret: s)
        }
    }
}
