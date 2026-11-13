// Ported from Recorditor (ZRecorditor @7210322, native/MacRecorder/Editor/PlayerContainerView.swift).
import AVFoundation
import AppKit
import SwiftUI

/// AVPlayerLayer wrapper so we can overlay our own controls and crop UI.
struct PlayerContainerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerNSView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
    }
}

final class PlayerNSView: NSView {
    let playerLayer = AVPlayerLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

/// Where the video actually appears inside a container, with aspect-fit.
func videoDisplayRect(container: CGSize, video: CGSize) -> CGRect {
    guard container.width > 0, container.height > 0, video.width > 0, video.height > 0 else { return .zero }
    let scale = min(container.width / video.width, container.height / video.height)
    let size = CGSize(width: video.width * scale, height: video.height * scale)
    return CGRect(
        x: (container.width - size.width) / 2,
        y: (container.height - size.height) / 2,
        width: size.width,
        height: size.height)
}
