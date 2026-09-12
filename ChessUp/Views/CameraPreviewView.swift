//
//  CameraPreviewView.swift
//  ChessUp
//
//  Created by William Silvano Angga on 12/09/26.
//
//  Thin UIViewRepresentable that shows CameraManager's live feed. This
//  is purely visual confirmation for whoever's holding the phone that
//  the board is framed correctly — VisionCoordinator consumes frames
//  independently via CameraManagerDelegate, so this view has no effect
//  on detection at all; you could delete it and the vision pipeline
//  would work identically, just with nothing on screen to look at.
//

import SwiftUI
import AVFoundation

struct CameraPreviewView: UIViewRepresentable {
    let cameraManager: CameraManager

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.previewLayer = cameraManager.previewLayer
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        uiView.previewLayer = cameraManager.previewLayer
    }
}

/// Plain UIView subclass so the preview layer's frame can be kept in
/// sync with layout via `layoutSubviews` — SwiftUI's UIViewRepresentable
/// doesn't call back into `updateUIView` on every layout pass (e.g.
/// rotation, safe-area changes), only on state changes, so relying on
/// that alone would leave the preview mis-sized after a rotation.
final class PreviewContainerView: UIView {
    var previewLayer: AVCaptureVideoPreviewLayer? {
        didSet {
            guard oldValue !== previewLayer else { return }
            oldValue?.removeFromSuperlayer()
            if let previewLayer {
                previewLayer.frame = bounds
                layer.addSublayer(previewLayer)
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }
}
