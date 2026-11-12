//
//  VideoBudget.swift
//  Greenroom
//
//  Who gets which video resolution, as pure arithmetic (no SDK, no AppKit).
//
//  Zoom publishes a concurrent budget for remote video on a desktop client and
//  the SDK enforces it with hard refusals (ZoomSDKVideoSubscribe_Fail_
//  HasSubscribe1080POr720P, _HasSubscribeTwo720P, _HasSubscribeExceededLimit):
//
//      1 x 1080p   2 x 720p   4 x 360p   17 x 180p   34 x 90p
//
//  Your own picture does not count. Every window that draws video asks for a
//  tier here before it subscribes, in the priority order below, so the budget is
//  spent on purpose instead of by whoever subscribed first (the "one works, the
//  other goes black" seesaw in ZoomMeetingSDKClient.resolution(for:)).
//
//  Order of priority (.context/meeting-views-plan.md, section 2):
//
//      1  Active speaker, Spotlight student   stage at 720p (360p if 720p is gone)
//      2  Speaker + strip                      stage 720p/360p, strip 180p
//      3  Multi-speaker                        3 x 360p
//      4  Meeting window                       what it already holds (external)
//      5  Gallery                              180p, or 90p under 200pt; page = free 180p
//      6  Self view                            360p, self is free
//
//  A request that already holds a tier inside its own range keeps it, so a
//  window that is already drawing is never reshuffled by one that opens later.
//
import Foundation

enum VideoTier: Int, Comparable, CaseIterable {
    case p90 = 90, p180 = 180, p360 = 360, p720 = 720

    static func < (a: VideoTier, b: VideoTier) -> Bool { a.rawValue < b.rawValue }

    /// How many streams of this tier Zoom allows at once.
    var quota: Int {
        switch self {
        case .p720: return 2        // 1080p takes one of these; this app never asks for 1080p
        case .p360: return 4
        case .p180: return 17
        case .p90: return 34
        }
    }

    /// The next tier down, if any.
    var lower: VideoTier? { VideoTier(rawValue: [90, 180, 360, 720].last { $0 < rawValue } ?? 0) }
}

/// How many streams of each tier are already in use.
struct VideoUsage: Equatable {
    private(set) var counts: [VideoTier: Int] = [:]

    init(_ counts: [VideoTier: Int] = [:]) { self.counts = counts }

    func count(_ tier: VideoTier) -> Int { counts[tier] ?? 0 }
    func free(_ tier: VideoTier) -> Int { max(0, tier.quota - count(tier)) }
    mutating func take(_ tier: VideoTier) { counts[tier, default: 0] += 1 }
}

struct VideoRequest: Equatable {
    /// Whoever asks: a window and slot, as text, so the budget stays pure.
    var key: String
    /// Lower is served first.
    var priority: Int
    /// The tier it would like, and the lowest it can live with.
    var wanted: VideoTier
    var floor: VideoTier
    /// The tier it holds now, if it is subscribed.
    var current: VideoTier?
}

enum VideoBudget {

    /// A tier for each request, or nil when even the floor is gone (the tile
    /// shows its placeholder and asks again later). `external` is what other
    /// owners already hold: the Meeting window's elements.
    static func allocate(_ requests: [VideoRequest], external: VideoUsage = VideoUsage()) -> [String: VideoTier?] {
        var usage = external
        var result: [String: VideoTier?] = [:]
        let ordered = requests.enumerated().sorted {
            ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset)
        }.map(\.element)

        // Pass 1: what is already running stays, if it is still inside its range.
        for r in ordered {
            if let held = r.current, held >= r.floor, held <= r.wanted, usage.count(held) < held.quota {
                usage.take(held)
                result[r.key] = held
            }
        }
        // Pass 2: everyone else, in priority order, from what they want down.
        for r in ordered where result[r.key] == nil {
            var tier: VideoTier? = r.wanted
            var got: VideoTier?
            while let candidate = tier, candidate >= r.floor {
                if usage.free(candidate) > 0 { got = candidate; break }
                tier = candidate.lower
            }
            if let got { usage.take(got) }
            result[r.key] = .some(got)
        }
        return result
    }

    /// The most Gallery tiles on a page: one per free 180p stream, at most 16
    /// (Zoom's own gallery page), and always at least one.
    static func galleryPageSize(used: VideoUsage) -> Int {
        max(1, min(16, used.free(.p180)))
    }

    /// A tile's size decides how much it can show: under 200pt tall a 90p stream
    /// is plenty.
    static func galleryTier(tileHeight: CGFloat) -> VideoTier { tileHeight < 200 ? .p90 : .p180 }
}

/// A place in a view window that shows one person.
enum ViewSlot: Hashable {
    /// The big picture of Active speaker, Spotlight, Speaker + strip.
    case stage
    /// Your own picture. Never counted against the budget.
    case selfView
    /// Multi-speaker's n-th place: the element stays, the person in it changes.
    case place(Int)
    /// A tile for one person (Gallery, the strip).
    case user(UInt32)
}
