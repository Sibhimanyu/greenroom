//
//  MeetingShareRules.swift
//  Greenroom
//
//  The meeting's sharing and chat rules, and which shared screen is on the
//  stage, as plain values. No SDK import: the client translates at the edge, so
//  all of this can be tested.
//
import Foundation

// MARK: - Who can share, and how many at once

enum WhoCanShare: Equatable { case hostOnly, everyone }
enum ConcurrentShare: Equatable { case one, multiple }

/// The two share choices Zoom's Security menu offers, over the SDK's one enum.
///
/// The raw values mirror `ZoomSDKShareSettingType` (ZoomSDKErrors.h:1178-1186):
///   0 OnlyHostCanGrab  anyone can share, one at a time, only the host can take over
///   1 OnlyHostCanShare only the host shares
///   2 AnyoneCanGrab    one at a time, and anyone can take over from the sharer
///   3 MultiShare       several people can share at once
///   4 None
/// There is no host-only-and-multi value: when only the host shares, how many
/// can share at once does not arise, so `concurrent` is remembered by the caller.
struct ShareRule: Equatable {
    var who: WhoCanShare
    var concurrent: ConcurrentShare

    /// Nil for `None` (4) and anything the SDK adds later.
    init?(sdkRaw: Int, remembering concurrent: ConcurrentShare = .one) {
        switch sdkRaw {
        case 0, 2: self.init(who: .everyone, concurrent: .one)
        case 1: self.init(who: .hostOnly, concurrent: concurrent)
        case 3: self.init(who: .everyone, concurrent: .multiple)
        default: return nil
        }
    }

    init(who: WhoCanShare, concurrent: ConcurrentShare) {
        self.who = who
        self.concurrent = concurrent
    }

    /// What to hand `setShareSettingType:`. "One at a time" is Zoom's own
    /// default, OnlyHostCanGrab: the host can take the screen, nobody else can.
    var sdkRaw: Int {
        switch (who, concurrent) {
        case (.hostOnly, _): return 1
        case (.everyone, .one): return 0
        case (.everyone, .multiple): return 3
        }
    }

    func setting(who: WhoCanShare) -> ShareRule { ShareRule(who: who, concurrent: concurrent) }
    func setting(concurrent: ConcurrentShare) -> ShareRule { ShareRule(who: who, concurrent: concurrent) }
}

// MARK: - Who can chat

/// What participants may do in chat. Raw values mirror `ZoomSDKChatPrivilegeType`
/// (ZoomSDKErrors.h:1383-1395): To_Everyone 0, To_Host 2, Disable_Attendee_Chat 3,
/// Host_Public 4. (1, To_All_Panelist, is for webinars.)
enum ChatWho: CaseIterable, Equatable {
    case nobody, hostOnly, everyonePublicly, everyone

    var sdkRaw: Int {
        switch self {
        case .nobody: return 3
        case .hostOnly: return 2
        case .everyonePublicly: return 4
        case .everyone: return 0
        }
    }

    init?(sdkRaw: Int) {
        guard let match = Self.allCases.first(where: { $0.sdkRaw == sdkRaw }) else { return nil }
        self = match
    }

    var title: String {
        switch self {
        case .nobody: return "No one"
        case .hostOnly: return "Host only"
        case .everyonePublicly: return "Everyone publicly"
        case .everyone: return "Everyone publicly and privately"
        }
    }
}

// MARK: - Which screen share is on the stage

/// The shares other people are running, in the order they began, and which one
/// the stage shows. The newest sharer wins; a pick from the chooser holds until
/// that share ends or someone newer starts.
struct ShareStageSelection: Equatable {
    private(set) var order: [UInt32] = []
    private(set) var picked: UInt32?

    var current: UInt32? {
        if let picked, order.contains(picked) { return picked }
        return order.last
    }

    var hasChoice: Bool { order.count > 1 }

    mutating func began(_ sourceID: UInt32) {
        order.removeAll { $0 == sourceID }
        order.append(sourceID)
        picked = nil
    }

    mutating func ended(_ sourceID: UInt32) {
        order.removeAll { $0 == sourceID }
        if picked == sourceID { picked = nil }
    }

    mutating func pick(_ sourceID: UInt32) {
        guard order.contains(sourceID) else { return }
        picked = sourceID
    }

    mutating func removeAll() {
        order = []
        picked = nil
    }
}

// MARK: - Opening the meeting in the Zoom app

enum ZoomAppLink {
    /// A `zoommtg://` link for the same meeting, so the Zoom app can open it for
    /// breakout rooms, polls and captions. Taken from the join link when there is
    /// one (its `pwd` is the encrypted form the scheme expects), else from the
    /// meeting number and passcode.
    static func make(joinURL: String, number: String, passcode: String) -> URL? {
        var host = "zoom.us"
        var confno = number.filter(\.isNumber)
        var pwd = ""
        if let url = URL(string: joinURL), let h = url.host, !h.isEmpty {
            host = h
            let parts = url.path.split(separator: "/")
            if let i = parts.firstIndex(of: "j"), i + 1 < parts.count {
                let digits = parts[i + 1].filter(\.isNumber)
                if !digits.isEmpty { confno = String(digits) }
            }
            if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
               let value = items.first(where: { $0.name == "pwd" })?.value {
                pwd = value
            }
        }
        guard !confno.isEmpty else { return nil }
        if pwd.isEmpty { pwd = passcode }
        var components = URLComponents()
        components.scheme = "zoommtg"
        components.host = host
        components.path = "/join"
        components.queryItems = [URLQueryItem(name: "confno", value: confno)]
            + (pwd.isEmpty ? [] : [URLQueryItem(name: "pwd", value: pwd)])
        return components.url
    }
}
