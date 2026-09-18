//
//  CameraPreviewView.swift
//  ChessUp
//
//  Created by William Silvano Angga on 12/09/26.
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
