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
    let manual: Bool
    let setUp: ZoomSetUpForMeState

    init(sdk: Bool = false, s2s: Bool = false, lines: [ZoomCheckLine] = [],
         assist: ZoomGuideAssistState = ZoomGuideAssistState(), manual: Bool = false, setUp: ZoomSetUpForMeState = .idle) {
        self.setUp = setUp
        self.assist = assist
        self.manual = manual
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
                          checkLines: lines, isChecking: false, jump: $jump, assist: assist, setUp: setUp, infoDefaults: InfoValues(name: "Sam Sample", email: "sam@example.com"),
                          onStopSetUp: {}, manualOpen: manual)
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

let keyFailure: [ZoomCheckLine] = [
    own("sdk", "Meeting and chat credentials", .failed, "Zoom did not accept the Client ID and Secret", .badCredentials),
    own("account", "Hosting credentials and app activation", .passed),
]

let hostingStep = SetupStep(number: 5, title: "Fill in Information", app: .hosting, why: "Zoom asks for a contact before it turns the app on.",
                            place: .s2s(hostID, .information), status: nil, cta: .goTo(.s2s(hostID, .information), "Open Information"))
let copyKeysStep = SetupStep(number: 3, title: "Copy its keys", app: .meeting, why: "Greenroom signs in to meetings with them.",
                             place: .general(appID, .information), status: nil, cta: .goTo(.general(appID, .information), "Open Basic information"))

MainActor.assumeIsolated {
    let ids2 = ZoomAppIDs(meeting: appID, hosting: hostID)
    for dark in [false, true] {
        let tag = dark ? "dark" : "light"
        // Set up for me: fresh, preparing, running (with Stop), handed over.
        shoot(Guide(), "1-fresh-set-up-for-me-\(tag)", dark: dark, height: 700)
        shoot(Guide(setUp: .preparing), "2-preparing-\(tag)", dark: dark, height: 700)
        shoot(Guide(setUp: .running("Step 3 of 8 \u{00B7} Copy its keys\u{2026}")), "3-running-stop-\(tag)", dark: dark, height: 700)
        shoot(Guide(setUp: .handedOver("Greenroom stopped at Step 5 of 8 \u{00B7} Fill in Information: Zoom did not let it type here. Carry on in the Zoom window.")),
              "4-handed-over-\(tag)", dark: dark, height: 700)
        shoot(Guide(setUp: .handedOver("You stopped it. Carry on in the Zoom window.")), "4b-handed-over-short-\(tag)", dark: dark, height: 700)
        // The sheet's content: the form, with and without existing apps.
        shoot(ZoomSetUpForMeForm(info: InfoValues(name: "Sam Sample", email: "sam@example.com"), existing: []), "5-form-new-\(tag)", dark: dark, width: 520, height: 520)
        shoot(ZoomSetUpForMeForm(info: InfoValues(name: "Sam Sample", email: "sam@example.com"), existing: [.meeting, .hosting]), "6-form-existing-apps-\(tag)", dark: dark, width: 520, height: 620)
        shoot(ZoomSetUpForMeForm(info: InfoValues(), existing: [.hosting]), "7-form-empty-\(tag)", dark: dark, width: 520, height: 620)
        // Parts, with the step line of the part in progress.
        shoot(Guide(sdk: true, assist: ZoomGuideAssistState(page: .s2s(hostID, .information), ids: ids2, step: hostingStep)), "8-meeting-done-step-line-\(tag)", dark: dark, height: 700)
        shoot(Guide(assist: ZoomGuideAssistState(page: .general(appID, .information), ids: ZoomAppIDs(meeting: appID), step: copyKeysStep)), "9-step-line-meeting-\(tag)", dark: dark, height: 700)
        shoot(Guide(sdk: true, s2s: true, lines: passedLines, assist: ZoomGuideAssistState(ids: ids2), setUp: .done), "10-both-done-and-checked-\(tag)", dark: dark, height: 760)
        shoot(Guide(sdk: true, assist: ZoomGuideAssistState(ids: ids2)), "11-meeting-done-\(tag)", dark: dark, height: 700)
        shoot(Guide(sdk: true, s2s: true, lines: keyFailure, assist: ZoomGuideAssistState(ids: ids2), manual: true), "12-check-with-a-key-failure-\(tag)", dark: dark, height: 1500)
        shoot(Guide(sdk: true, s2s: true, lines: failedLines, assist: ZoomGuideAssistState(ids: ids2), manual: true), "13-check-with-missing-scopes-\(tag)", dark: dark, height: 1700)
        shoot(Guide(assist: ZoomGuideAssistState(removed: [.meetingApp])), "14-keys-removed-undo-\(tag)", dark: dark, height: 700)
    }
}
