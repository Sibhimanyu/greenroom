// Off-screen render of the setup guide's Zoom step, per flow state. Staged data only.
import SwiftUI
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

@MainActor func shoot<V: View>(_ v: V, _ file: String, dark: Bool, width: CGFloat = 680, height: CGFloat) {
    let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: width, height: height), styleMask: [.titled],
                       backing: .buffered, defer: false)
    let host = NSHostingView(rootView: v.frame(width: width, height: height).background(Color(nsColor: .windowBackgroundColor)))
    win.contentView = host
    win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    win.orderBack(nil); spin(0.8)
    host.layoutSubtreeIfNeeded()
    let b = host.bounds
    let rep = host.bitmapImageRepForCachingDisplay(in: b)!
    host.cacheDisplay(in: b, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(file).png"))
    print("wrote \(file)")
    win.orderOut(nil)
}

let ids = ZoomCheckActionContext(sdkClientID: "SampleClientID9z7Q", s2sClientID: "SampleS2Sk3Rw")
func own(_ id: String, _ title: String, _ status: ZoomCheckStatus, _ detail: String = "",
         _ problem: ZoomCheckProblem = .nothing) -> ZoomCheckLine {
    ZoomCheckLine(id: id, title: title, status: status, detail: detail,
                  actions: ZoomCheckActionRules.buttons(.ownApps, check: id, status: status, problem: problem, ids: ids))
}
let passedLines = (0..<12).map { own("p\($0)", "check", .passed) }
let failedLines: [ZoomCheckLine] = [
    own("sdk", "Meeting and chat credentials", .passed),
    own("account", "Hosting credentials and app activation", .passed),
    own("update", "Permission to edit scheduled meetings", .failed, "Missing", .missingScopes(["meeting:update:meeting:admin"])),
    own("delete", "Permission to delete scheduled meetings", .failed, "Missing", .missingScopes(["meeting:delete:meeting:admin"])),
    own("host", "Permission to get the hosting token", .passed),
    ZoomScopeLineRules.line(ZoomScopes.scope(.personalRoom), granted: [], ids: ids),
]

/// The step inside the guide's frame (24pt padding), with the footer's note line under it.
struct Guide: View {
    @State var sdkID: String
    @State var sdkSecret: String
    @State var acct: String
    @State var s2sID: String
    @State var s2sSecret: String
    @State var jump: ZoomGuideSpot? = nil
    let lines: [ZoomCheckLine]
    let assist: ZoomGuideAssistState
    let open: ZoomGuidePart?

    init(sdk: Bool = false, s2s: Bool = false, lines: [ZoomCheckLine] = [],
         assist: ZoomGuideAssistState = ZoomGuideAssistState(), open: ZoomGuidePart? = nil) {
        self.assist = assist
        self.open = open
        _sdkID = State(initialValue: sdk ? "SampleClientID9z7Q" : "")
        _sdkSecret = State(initialValue: sdk ? "secret" : "")
        _acct = State(initialValue: s2s ? "SampleAccount" : "")
        _s2sID = State(initialValue: s2s ? "SampleS2Sk3Rw" : "")
        _s2sSecret = State(initialValue: s2s ? "secret" : "")
        self.lines = lines
    }

    var note: String? {
        ZoomGuideFlowRules.flow(ZoomGuideFlowRules.facts(sdkFields: [sdkID, sdkSecret], s2sFields: [acct, s2sID, s2sSecret],
                                                         lines: lines, running: false)).footerNote
    }

    var body: some View {
        VStack(spacing: 0) {
            ZoomGuideStep(sdkClientID: $sdkID, sdkClientSecret: $sdkSecret, s2sAccountID: $acct,
                          s2sClientID: $s2sID, s2sClientSecret: $s2sSecret,
                          checkLines: lines, isChecking: false, jump: $jump, assist: assist, initiallyOpen: open)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(24)
            Divider()
            HStack(spacing: 12) {
                Button("Back") {}
                if let note { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                else { Text("Changes save automatically").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Set up your meeting") {}.buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
    }
}

let appID = "AbC_123-xyZ789qrstuvw1"
let hostID = "ZzZ_999-aaBBcc1122"

MainActor.assumeIsolated {
    for dark in [false, true] {
        let tag = dark ? "dark" : "light"
        shoot(Guide(), "1-nothing-filled-in-\(tag)", dark: dark, height: 900)
        shoot(Guide(sdk: true), "2-part-1-done-\(tag)", dark: dark, height: 1340)
        shoot(Guide(sdk: true, s2s: true), "3-parts-1-and-2-done-\(tag)", dark: dark, height: 640)
        shoot(Guide(sdk: true, s2s: true, lines: passedLines), "4-all-done-and-checked-\(tag)", dark: dark, height: 560)
        shoot(Guide(sdk: true, s2s: true, lines: failedLines), "5-check-with-failures-\(tag)", dark: dark, height: 1340)
        // The Zoom window's part. Nothing known yet: step 1 offers "Create the app".
        shoot(Guide(open: .hostingApp), "6-no-app-id-known-hosting-\(tag)", dark: dark, height: 1340)
        shoot(Guide(sdk: true, assist: ZoomGuideAssistState(page: .general(appID, .embed), ids: ZoomAppIDs(meeting: appID)), open: .meetingApp),
              "7-ids-known-meeting-step-2-\(tag)", dark: dark, height: 900)
        shoot(Guide(sdk: true, assist: ZoomGuideAssistState(page: .s2s(hostID, .scopes), ids: ZoomAppIDs(meeting: appID, hosting: hostID)), open: .hostingApp),
              "8-ids-known-hosting-step-2-\(tag)", dark: dark, height: 1340)
        shoot(Guide(sdk: true, s2s: true, assist: ZoomGuideAssistState(page: .s2s(hostID, .credentials), ids: ZoomAppIDs(meeting: appID, hosting: hostID),
                                                                       filled: [.hostingApp]), open: .hostingApp),
              "9-filled-in-from-zoom-\(tag)", dark: dark, height: 1340)
        shoot(Guide(sdk: true, assist: ZoomGuideAssistState(page: .general(appID, .information), ids: ZoomAppIDs(meeting: appID),
                                                            offers: [.meetingApp]), open: .meetingApp),
              "10-offer-use-keys-\(tag)", dark: dark, height: 900)
        // The ways back: Start over (under the parts) and Use a different app (under a Done part's fields).
        shoot(Guide(sdk: true, assist: ZoomGuideAssistState(ids: ZoomAppIDs(meeting: appID)), open: .meetingApp),
              "11-start-over-and-use-a-different-app-\(tag)", dark: dark, height: 900)
        shoot(Guide(assist: ZoomGuideAssistState(removed: [.meetingApp]), open: .meetingApp),
              "12-keys-removed-undo-\(tag)", dark: dark, height: 900)
        // Keys filled but no app ID known: step 1 reads Find my app.
        shoot(Guide(s2s: true, open: .hostingApp), "13-find-my-app-\(tag)", dark: dark, height: 1340)
    }
}
