import AonsokuKit
import AVFoundation
import SwiftUI
import UIKit

/// Video shares the phone's single artwork slot; no separate audio player is created.
struct DynamicPlayerArtwork: UIViewRepresentable {
    let coverArtId: String
    let playing: Bool
    let active: Bool

    final class VideoView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var videoLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    final class Coordinator {
        let owner = UUID()
        var cover: String?
        var requested = false
        var active = false
        var playing = false
        var generation = 0
        var loading = false
        var lease: DynamicArtworkLease?
        var player: AVQueuePlayer?
        var looper: AVPlayerLooper?
        var notification: NSObjectProtocol?
        weak var view: VideoView?

        func refresh() {
            guard active, !loading, let cover else { return }
            loading = true
            let revision = generation
            AppServices.shared.audio.dynamicArtwork(coverArtId: cover) { [weak self] lease in
                guard let self, self.generation == revision else { return }
                self.loading = false
                guard let lease, self.lease?.url != lease.url else { return }
                self.player?.pause()
                self.lease = lease
                let player = AVQueuePlayer()
                player.isMuted = true
                player.preventsDisplaySleepDuringVideoPlayback = false
                self.player = player
                self.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: lease.url))
                self.view?.videoLayer.player = player
                if self.playing, self.active { player.play() }
            }
        }
        func reset() {
            generation += 1
            loading = false
            player?.pause()
            view?.videoLayer.player = nil
            player = nil
            looper = nil
            lease = nil
            AppServices.shared.audio.releaseDynamicArtwork(owner: owner)
            requested = false
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> VideoView {
        let view = VideoView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.videoLayer.videoGravity = .resizeAspectFill
        context.coordinator.view = view
        context.coordinator.notification = NotificationCenter.default.addObserver(
            forName: .aonsokuDynamicArtworkChanged, object: nil, queue: .main) { [weak coordinator = context.coordinator] _ in
                coordinator?.refresh()
            }
        return view
    }
    func updateUIView(_ view: VideoView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.cover != coverArtId || coordinator.active != active { coordinator.reset() }
        coordinator.cover = coverArtId
        coordinator.active = active
        coordinator.playing = playing
        if active {
            if !coordinator.requested {
                coordinator.requested = AppServices.shared.audio.requestDynamicArtwork(coverArtId: coverArtId, owner: coordinator.owner) != nil
            }
            coordinator.refresh()
        }
        if active && playing { coordinator.player?.play() } else { coordinator.player?.pause() }
    }
    static func dismantleUIView(_ view: VideoView, coordinator: Coordinator) {
        coordinator.reset()
        if let token = coordinator.notification { NotificationCenter.default.removeObserver(token) }
    }
}
