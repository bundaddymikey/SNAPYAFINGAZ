import SwiftUI
import AVFoundation

// MARK: - CaptureServicePreviewLayer (Photo/Video path)
// Wraps CaptureService's AVCaptureVideoPreviewLayer for display in CaptureView.
// This was missing — CaptureView was showing Color.black instead of the camera feed.

struct CaptureServicePreviewLayer: UIViewRepresentable {
    let captureService: CaptureService

    func makeUIView(context: Context) -> CaptureServicePreviewUIView {
        let view = CaptureServicePreviewUIView()
        #if DEBUG
        print("[CaptureServicePreviewLayer] makeUIView — photo/video preview host created")
        #endif
        return view
    }

    func updateUIView(_ uiView: CaptureServicePreviewUIView, context: Context) {
        guard let layer = captureService.previewLayer else {
            #if DEBUG
            print("[CaptureServicePreviewLayer] updateUIView — previewLayer not ready yet")
            #endif
            return
        }
        uiView.attach(previewLayer: layer)
    }
}

// MARK: - CaptureServicePreviewUIView

final class CaptureServicePreviewUIView: UIView {
    private(set) var previewLayer: AVCaptureVideoPreviewLayer?

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }

    /// Attach or re-use the preview layer. Idempotent — safe to call multiple times.
    func attach(previewLayer layer: AVCaptureVideoPreviewLayer) {
        if layer === previewLayer {
            layer.frame = bounds
            return
        }
        previewLayer?.removeFromSuperlayer()
        layer.videoGravity = .resizeAspectFill
        layer.frame = bounds
        self.layer.insertSublayer(layer, at: 0)
        previewLayer = layer
        #if DEBUG
        print("[CaptureServicePreviewUIView] Preview layer attached — bounds: \(bounds)")
        #endif
    }
}
