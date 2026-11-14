import AVFoundation
import SwiftUI
import UIKit

/// Native AVPlayerLayer host for actual, server-approved preview clips.
/// The layer is mounted with a clear background so the real poster beneath
/// it remains visible before AVFoundation has its first video frame ready.
/// Keep the rendering layer attached rather than hiding/alpha-zeroing it:
/// hidden renderers may defer their own frame readiness notification.
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
        view.isOpaque = false
        view.backgroundColor = .clear
        view.playerLayer.isOpaque = false
        view.playerLayer.backgroundColor = UIColor.clear.cgColor
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
            // AVPlayerLayer documents that it presents NO video content until
            // isReadyForDisplay. Let the opaque server poster below show
            // through instead of hiding the layer and delaying decoding.
            playerLayer.player = player
            // KVO may deliver callbacks after an attachment is dismantled.
            // Recheck the exact layer lease on the main actor before sending
            // presentation readiness. The video has no opaque placeholder.
            observation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) {
                [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.attachmentEpoch == epoch,
                          self.playerLayer.player != nil else { return }
                    let ready = self.playerLayer.isReadyForDisplay
                    self.onReadyForDisplay?(ready)
                }
            }
        }

        func detach() {
            attachmentEpoch &+= 1
            observation?.invalidate()
            observation = nil
            playerLayer.player = nil
        }

        // The observation token invalidates on release; dismantleUIView
        // explicitly revokes the attachment, so no nonisolated deinit access
        // to a main-actor UIKit property is necessary.
    }
}
