// Off-screen render of Home's Camera and Screen pop-outs side by side, plus the new who-sees icons.
// Sample data only. The panels are rebuilt from the real shared components (HomeTilePanel,
// HomeTileChoiceRow, HomeTileList, HomeTileToggleRow); the coordinator-bound bodies are not compiled.
import SwiftUI
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

struct SampleRow: Identifiable { var id: String; var symbol: String }

struct CameraSample: View {
    @State var mirror = true
    @State var switching = true
    var body: some View {
        HomeTilePanel(title: "Camera", summary: "Which camera you appear on.", value: "MacBook Pro",
                      moreTitle: "More camera settings\u{2026}", onMore: {}) {
            HomeTileSection(title: "Who sees my camera") {
                HomeTileChoiceRow(
                    choices: CameraState.allCases.map {
                        HomeTileChoice(id: $0.raw, title: $0.name, symbol: VisibilitySymbol.camera($0).name,
                                       selected: $0 == .everyoneAndMe, badge: VisibilitySymbol.camera($0).badge)
                    },
                    labelLines: 2, pick: { _ in })
                Text(CameraState.everyoneAndMe.detail + " Only for this meeting.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HomeTileSection(title: "Cameras") {
                let rows = [("MacBook Pro Camera", "laptopcomputer"), ("Studio Display Camera", "display")].map { SampleRow(id: $0.0, symbol: $0.1) }
                HomeTileList(rows: rows, selected: { $0.id == rows[0].id }, pick: { _ in }) { row, keyed in
                    HomeTileListRow(symbol: row.symbol, title: row.id, selected: row.id == rows[0].id, keyFocused: keyed) {}
                }
            }
            HomeTileToggleRow(title: "Switch to the camera you\u{2019}re facing", isOn: $switching)
            HomeTileToggleRow(title: "Mirror my camera", isOn: $mirror)
        }
    }
}

struct ScreenSample: View {
    @State var follow = true
    var body: some View {
        HomeTilePanel(title: "Screen", summary: "What everyone sees behind you.", value: "Whole screen",
                      moreTitle: "More screen settings\u{2026}", onMore: {}) {
            HomeTileSection(title: "Share") {
                HomeTileChoiceRow(
                    choices: [("Whole screen", "rectangle.on.rectangle"), ("A window", "macwindow"), ("Whiteboard", "scribble"), ("Just me", "person.crop.rectangle")]
                        .enumerated().map { HomeTileChoice(id: "\($0.offset)", title: $0.element.0, symbol: $0.element.1, selected: $0.offset == 0) },
                    pick: { _ in })
            }
            HomeTileSection(title: "Displays") {
                HomeTileList(rows: [SampleRow(id: "d", symbol: "display")], selected: { _ in true }, pick: { _ in }) { _, keyed in
                    HomeTileListRow(symbol: "display", title: "Built-in Display", selected: true, keyFocused: keyed) {}
                }
            }
            HomeTileToggleRow(title: "Follow slide shows", isOn: $follow)
        }
    }
}

struct Icons: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([VisibilitySymbol.nobodyInCamera, .twoDisplays, .noPieces, .share, .everyoneSees(false)], id: \.words) { s in
                HStack(spacing: 10) {
                    Image(systemName: s.name).font(.system(size: 20)).frame(width: 32)
                    Text("\(s.words)  \(s.name)").font(.system(size: 12))
                }
            }
        }.padding(16).frame(width: 300, alignment: .leading)
    }
}

func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
func shoot<V: View>(_ v: V, _ file: String) {
    let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 800, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
    let host = NSHostingView(rootView: v)
    win.contentView = host
    win.appearance = NSAppearance(named: .aqua)
    win.orderBack(nil)
    spin(0.8)
    let fit = host.fittingSize
    win.setContentSize(fit); spin(0.4); host.layoutSubtreeIfNeeded()
    let b = host.bounds
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width * 2), pixelsHigh: Int(b.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = b.size
    host.cacheDisplay(in: b, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(file).png"))
    print("wrote \(file) \(Int(b.width))x\(Int(b.height))")
    win.orderOut(nil)
}
let panelBackdrop = { (v: AnyView) in AnyView(v.background(Color(nsColor: .windowBackgroundColor))) }
shoot(HStack(alignment: .top, spacing: 24) {
    CameraSample().background(Color(nsColor: .windowBackgroundColor)).border(Color.gray.opacity(0.4))
    ScreenSample().background(Color(nsColor: .windowBackgroundColor)).border(Color.gray.opacity(0.4))
}.padding(20).background(Color(white: 0.85)), "camera-vs-screen")
shoot(Icons(), "icons")
