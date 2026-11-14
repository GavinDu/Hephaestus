import AVFoundation
import SwiftUI
import UIKit

/// Native AVPlayerLayer host for actual, server-approved preview clips.
/// The shared layer is transparent until AVFoundation reports the current
/// item's *first video frame ready for display*. Without that gate a black
/// layer obscures the authentic poster during the network/decode gap.
/// This is NOT a gameplay-renderer readiness signal for WKWebView/Game IR.
struct FeedPreviewSurface: UIViewRepresentable {
    let player: AVPlayer
    let onReadyForDisplay: ((Bool) -> Void)?

    init(player: AVPlayer, onReadyForDisplay: ((Bool) -> Void)? = nil) {
        self.player = player
        self.onReadyForDisplay = onReadyForDisplay
    }

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.videoGravity = .resizeAspect
        view.onReadyForDisplay = onReadyForDisplay
        view.attach(player)
        return view
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        uiView.onReadyForDisplay = onReadyForDisplay
        if uiView.playerLayer.player !== player {
            uiView.attach(player)
        }
    }

    static func dismantleUIView(_ uiView: PlayerLayerView, coordinator: ()) {
        uiView.detach()
        uiView.onReadyForDisplay = nil
    }

    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        var onReadyForDisplay: ((Bool) -> Void)?
        private var observation: NSKeyValueObservation?
        private var attachmentEpoch: UInt64 = 0

        func attach(_ player: AVPlayer) {
            observation?.invalidate()
            observation = nil
            attachmentEpoch &+= 1
            let epoch = attachmentEpoch
            alpha = 0
            playerLayer.player = player
            // KVO may deliver callbacks after an attachment is dismantled.
            // Recheck the exact layer lease on the main actor before changing
            // the native image or sending presentation readiness.
            observation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) {
                [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.attachmentEpoch == epoch,
                          self.playerLayer.player != nil else { return }
                    let ready = self.playerLayer.isReadyForDisplay
                    self.alpha = ready ? 1 : 0
                    self.onReadyForDisplay?(ready)
                }
            }
        }

        func detach() {
            attachmentEpoch &+= 1
            observation?.invalidate()
            observation = nil
            alpha = 0
            playerLayer.player = nil
        }

        // The observation token invalidates on release; dismantleUIView
        // explicitly revokes the attachment, so no nonisolated deinit access
        // to a main-actor UIKit property is necessary.
    }
}
