// Off-screen render of Settings -> Layouts (scripts/render/layouts.sh). Sample data only: no app launch,
// no camera, no screen capture. The accessory activation policy never takes focus.
import SwiftUI
import AppKit

struct Case {
    let file: String
    let starter: String
    let twoDisplays: Bool
    let select: (LayoutTemplate) -> UUID?
    let slot: LayoutSlot
    var opensLook = false
    var addsSecond = false
    /// What is shared, for the canvas marks (R34).
    var target = Visibility.Target.wholeScreen
    /// Render the share pop-out (R32) on its own instead of the page.
    var popout = false
    var width: CGFloat = 760
    /// The camera state for the camera model (the canvas caption and the inspector's four segments).
    var state = CameraState.everyoneAndMe
    /// Own layouts added after the built-ins, so the strip has to scroll.
    var extraLayouts = 0
}

struct Host: View {
    @State var library: LayoutLibrary
    @State var restores = true
    @State var suggestions = true
    @State var lookBackground = CameraBackground.image
    @State var lookImage = CameraBackgroundPreset.defaultChoice
    @State var lookRemoval = BackgroundRemoval.automatic
    @State var lookMirror = true
    let c: Case
    let template: LayoutTemplate
    var body: some View {
        if c.popout {
            LayoutSharePopout(share: { var t = ShareTarget(); t.kind = .window; t.appBundleID = "com.apple.Safari"; t.appName = "Safari"; return t }(),
                              apps: [AppInfo(bundleID: "com.apple.Safari", name: "Safari", url: nil),
                                     AppInfo(bundleID: "com.apple.Notes", name: "Notes", url: nil)],
                              camera: nil, set: { _ in }, sharedDisplay: .constant(.main))
                .background(Color(nsColor: .windowBackgroundColor))
        } else { page }
    }
    @ViewBuilder var page: some View {
        let main = DisplayInfo(id: "main", displayID: 1, name: "Built-in Display", isMain: true, pixelWidth: 2880, pixelHeight: 1800)
        let second = DisplayInfo(id: "second", displayID: 2, name: "Studio Display", isMain: false, pixelWidth: 3840, pixelHeight: 2160)
        LayoutPageContent(
            library: $library, browserRestoresTabs: $restores, browserSearchSuggestions: $suggestions,
            apps: [AppInfo(bundleID: "com.apple.Safari", name: "Safari", url: nil),
                   AppInfo(bundleID: "com.apple.Notes", name: "Notes", url: nil)],
            displays: c.twoDisplays ? [main, second] : [main],
            mainSize: CGSize(width: 1440, height: 875),
            secondSize: { _ in c.twoDisplays ? CGSize(width: 1920, height: 1055) : nil },
            canMoveApps: true,
            openAccessibilitySettings: {}, showOnScreen: { _, _ in },
            camera: LayoutCameraModel(box: PresenceBox(), shape: WebcamShape.allCases.first!,
                                      cameraOff: !c.state.iSee, everyoneSees: c.state.everyoneSees,
                                      onStep: { _ in }, onCommit: { _ in }, state: c.state,
                                      look: CameraLookModel(background: $lookBackground, backgroundImage: $lookImage,
                                                            removal: $lookRemoval, mirror: $lookMirror, chooseImage: {})),
            share: c.target, fallbackShare: ShareTarget(),
            opensOn: (selection: c.select(template), slot: c.slot),
            opensLookGroup: c.opensLook)
        .frame(width: c.width)
    }
}

let outDir = CommandLine.arguments[1]
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let chatID: (LayoutTemplate) -> UUID? = { $0.oneDisplay.first { $0.kind.isChat }?.id }
let cases: [Case] = [
    // No second arrangement: the main canvas fills the panel, the dashed strip adds a second display.
    Case(file: "1-no-second-strip", starter: LayoutLibrary.roomLaptop, twoDisplays: false, select: { _ in nil }, slot: .main),
    Case(file: "5-no-second-strip-connected", starter: LayoutLibrary.roomLaptop, twoDisplays: true, select: { _ in nil }, slot: .main),
    // A second arrangement: both canvases side by side.
    Case(file: "2-with-second", starter: LayoutLibrary.rajMode, twoDisplays: true, select: { _ in nil }, slot: .main),
    Case(file: "3-camera", starter: LayoutLibrary.rajMode, twoDisplays: true, select: { _ in LayoutCameraModel.selectionID }, slot: .main),
    Case(file: "4-chat", starter: LayoutLibrary.rajMode, twoDisplays: true, select: chatID, slot: .main),
    Case(file: "8-second-just-added", starter: LayoutLibrary.roomLaptop, twoDisplays: true, select: { _ in nil }, slot: .main, addsSecond: true),
    Case(file: "9-second-not-connected", starter: LayoutLibrary.rajMode, twoDisplays: false, select: { _ in nil }, slot: .main),
    Case(file: "7-hidden", starter: LayoutLibrary.roomLaptop, twoDisplays: false, select: { _ in nil }, slot: .main),
    // R32 to R35 (next-ui-refine): the share pop-out, the simple inspectors, the One-window canvas.
    Case(file: "10-share-popover", starter: LayoutLibrary.rajMode, twoDisplays: true, select: { _ in nil }, slot: .main, popout: true, width: 330),
    Case(file: "11-camera-inspector", starter: LayoutLibrary.rajMode, twoDisplays: true, select: { _ in LayoutCameraModel.selectionID }, slot: .main),
    Case(file: "12-chat-inspector", starter: LayoutLibrary.rajMode, twoDisplays: true, select: chatID, slot: .main),
    Case(file: "13-meeting-inspector", starter: LayoutLibrary.rajMode, twoDisplays: true,
         select: { $0.twoDisplays?.second.first { $0.kind.isMeeting }?.id }, slot: .second),
    Case(file: "14-one-window-share", starter: LayoutLibrary.rajMode, twoDisplays: true, select: { _ in nil }, slot: .main,
         target: .window(bundleID: "com.sibhimanyu.greenroom.browser")),
    Case(file: "15-app-inspector", starter: LayoutLibrary.rajMode, twoDisplays: true,
         select: { $0.oneDisplay.first { $0.kind.app != nil }?.id }, slot: .main),
    // Owner, 2026-11-26: the strip (Leave my windows alone first, fade when it scrolls) and the camera in each state.
    Case(file: "20-strip-three", starter: LayoutLibrary.leaveAlone, twoDisplays: false, select: { _ in nil }, slot: .main),
    Case(file: "21-strip-scrolls", starter: LayoutLibrary.leaveAlone, twoDisplays: false, select: { _ in nil }, slot: .main, extraLayouts: 4),
    Case(file: "22-strip-scrolls-last-chosen", starter: LayoutLibrary.leaveAlone, twoDisplays: false, select: { _ in nil }, slot: .main, extraLayouts: 4),
    Case(file: "30-camera-everyone-me", starter: LayoutLibrary.roomLaptop, twoDisplays: false, select: { _ in LayoutCameraModel.selectionID }, slot: .main, state: .everyoneAndMe),
    Case(file: "31-camera-only-the-meeting", starter: LayoutLibrary.roomLaptop, twoDisplays: false, select: { _ in LayoutCameraModel.selectionID }, slot: .main, state: .onlyEveryone),
    Case(file: "32-camera-only-me", starter: LayoutLibrary.roomLaptop, twoDisplays: false, select: { _ in LayoutCameraModel.selectionID }, slot: .main, state: .onlyMe),
    Case(file: "33-camera-off", starter: LayoutLibrary.roomLaptop, twoDisplays: false, select: { _ in LayoutCameraModel.selectionID }, slot: .main, state: .off),
    Case(file: "6-camera-look", starter: LayoutLibrary.rajMode, twoDisplays: true, select: { _ in LayoutCameraModel.selectionID }, slot: .main, opensLook: true),
]

func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

for c in cases {
    var lib = LayoutLibrary(templates: LayoutLibrary.starters())
    var t = lib.templates.first { $0.starter == c.starter }!
    for i in 0..<c.extraLayouts { lib.templates.append(LayoutTemplate(name: "My layout \(i + 1)", camera: LayoutCamera.rounded, share: ShareTarget())) }
    if c.file.hasPrefix("22-") { t = lib.templates.last! }
    lib.select(t.id)
    if c.addsSecond {
        var h = t; h.addSecondDisplay(); lib.update(h)
    }
    if c.file == "7-hidden" {   // a piece that starts hidden, and the camera as Only me
        var h = t
        for i in h.oneDisplay.indices where h.oneDisplay[i].kind.view != nil { h.oneDisplay[i].kind = .view(h.oneDisplay[i].kind.view!, startsHidden: true) }
        lib.update(h)
    }
    let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: c.width, height: 1500),
                       styleMask: [.titled], backing: .buffered, defer: false)
    let host = NSHostingView(rootView: Host(library: lib, c: c, template: t))
    win.contentView = host
    win.appearance = NSAppearance(named: .aqua)
    win.orderBack(nil)   // laid out, never raised, never key
    spin(1.2)
    host.layoutSubtreeIfNeeded()
    let fit = host.fittingSize.height
    if fit > 200 && fit < 1500 { win.setContentSize(NSSize(width: c.width, height: fit)); spin(0.5); host.layoutSubtreeIfNeeded() }
    let b = host.bounds
    let rep = host.bitmapImageRepForCachingDisplay(in: b)!
    let scaled = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width * 2), pixelsHigh: Int(b.height * 2),
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    scaled.size = b.size
    _ = rep
    host.cacheDisplay(in: b, to: scaled)
    let png = scaled.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: "\(outDir)/\(c.file).png"))
    print("wrote \(c.file) \(Int(b.width))x\(Int(b.height))")
    win.orderOut(nil)
}
