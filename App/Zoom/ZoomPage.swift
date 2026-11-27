//
//  ZoomPage.swift
//  Greenroom
//
//  The ZoomPage seam (docs/specs/zoom-setup-flow.md): everything the setup flow needs from a Zoom
//  Marketplace page, as three verbs. `read` reports the page as plain data, `perform` does one
//  action on one named control (or loads an address), `draw` shows the coach. Two adapters: the
//  WKWebView page (ZoomMarketplaceWindow) and `FixturePage` (tests), so the seam is real.
//  Pure: Foundation only.
//
import Foundation

/// One thing done on the page. Controls are named by ID, never by label.
enum ZoomPageAction: Equatable {
    case press(ZoomControl)
    /// A press for controls whose handler sits on an inner icon (the General app's Copy).
    case pressDeep(ZoomControl)
    case hover(ZoomControl)
    case type(ZoomControl, String)
    /// Loading an address is navigation, not clicking.
    case navigate(ZoomMarketplacePage)
}

enum ZoomActionResult: Equatable {
    case done
    /// The control is not on the page right now.
    case notFound
    /// The deny-list matched the element's text at press time.
    case denied
}

/// What the coach shows: a ring around one control (when it is on the page), a card, one action button.
struct CoachDrawing: Equatable, Codable {
    var control: ZoomControl?
    var counter: String
    var title: String
    var why: String
    var status: String?
    /// The single action button's label (nil: the card alone).
    var button: String?
}

@MainActor
protocol ZoomPage: AnyObject {
    /// nil: the page could not be read (loading, or not a Marketplace page).
    func read() async -> ZoomPageSnapshot?
    func perform(_ action: ZoomPageAction) async -> ZoomActionResult
    /// The key text Zoom's own Copy handed over since the last call (the window's copy hook); nil if none.
    func takeCopiedKey() -> String?
    func draw(_ coach: CoachDrawing?)
}

/// How long a wait looks: `polls` reads, `pause` nanoseconds apart.
struct ZoomPacing: Equatable {
    var polls: Int
    var pause: UInt64
    static let live = ZoomPacing(polls: 60, pause: 250_000_000)   // 15s: Zoom drew a page's controls 7s late (live run 7)
    static let instant = ZoomPacing(polls: 8, pause: 0)
}
