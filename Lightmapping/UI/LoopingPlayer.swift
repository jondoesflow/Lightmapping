import AVFoundation
import SwiftUI

/// Full-screen seamless loop of a received show. AVPlayer also drives AirPlay/HDMI
/// mirroring, so a receiver wired to a projector plays it there.
struct LoopingPlayer: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PlayerView {
        let v = PlayerView()
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        context.coordinator.looper = AVPlayerLooper(player: player, templateItem: item)
        player.allowsExternalPlayback = true
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        player.play()
        return v
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {}

    static func dismantleUIView(_ uiView: PlayerView, coordinator: Coordinator) {
        uiView.playerLayer.player?.pause()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var looper: AVPlayerLooper? }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
