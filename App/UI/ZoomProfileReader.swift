//
//  ZoomProfileReader.swift
//  Greenroom
//
//  Reads the signed-in Zoom account's name and email from zoom.us/profile in a web view with no
//  window, using the Zoom window's sign-in (the same default data store). Read-only: it loads the
//  page and reads its visible text, never clicks or types. The text is parsed by `ZoomProfile` and
//  kept in memory only, to pre-fill Set up for me's form.
//
import WebKit

@MainActor
final class ZoomProfileReader: NSObject, WKNavigationDelegate {
    private static let profileURL = URL(string: "https://zoom.us/profile")!
    private var web: WKWebView?
    private var reader: ZoomProfileReader?

    /// The account's own details, or nothing found within about 15 seconds.
    static func read() async -> ZoomProfile.Found {
        let r = ZoomProfileReader()
        r.reader = r
        defer { r.web?.stopLoading(); r.web = nil; r.reader = nil }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900), configuration: config)
        web.customUserAgent = ZoomMarketplaceWindow.safariUA
        r.web = web
        web.load(URLRequest(url: profileURL))
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let host = web.url?.host, host == "zoom.us" || host.hasSuffix(".zoom.us") else { continue }
            let text = (try? await web.evaluateJavaScript("document.body ? document.body.innerText : ''")) as? String ?? ""
            let found = ZoomProfile.parse(text)
            if found.email != nil { return found }
        }
        return ZoomProfile.Found()
    }
}
