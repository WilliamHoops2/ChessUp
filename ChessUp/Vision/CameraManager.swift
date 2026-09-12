//
//  CameraManager.swift
//  ChessUp
//
//  Created by William Silvano Angga on 12/09/26.
//
//  Thin wrapper around AVFoundation that streams pixel buffers to a
//  delegate/closure. Kept deliberately dumb — it knows nothing about
//  chess. `BoardDetector` (or a future CoreML pipeline) consumes the
//  frames it produces.
//
//  Setup checklist:
//   - Add `NSCameraUsageDescription` to Info.plist ("ChessUp uses the
//     camera to read the board and pieces during play.")
//   - This targets the back camera in landscape, mounted looking down
//     at the board — matches the "phone propped above the board" setup
//     described in the app spec.
//

import AVFoundation
import CoreImage

protocol CameraManagerDelegate: AnyObject {
    func cameraManager(_ manager: CameraManager, didCapture pixelBuffer: CVPixelBuffer)
}

final class CameraManager: NSObject {
    weak var delegate: CameraManagerDelegate?

    private let session = AVCaptureSession()
    private let videoQueue = DispatchQueue(label: "com.chessup.camera.video")

    /// Throttle: board state doesn't need 30fps analysis — the board is
    /// static except right when a piece moves. Analyzing every frame
    /// wastes battery/thermal budget for no benefit.
    private var lastAnalysisTime: CFAbsoluteTime = 0
    private let minAnalysisInterval: CFAbsoluteTime = 0.5

    /// Cached rather than recomputed: an AVCaptureVideoPreviewLayer is
    /// meant to be created once and reused for the life of the session.
    /// Handing back a fresh one on every access (as this used to do)
    /// meant a SwiftUI UIViewRepresentable calling this from
    /// `updateUIView` would keep creating layers that were never the
    /// one actually attached to a view — net effect: a black screen
    /// even though frames were flowing to the delegate the whole time.
    private(set) lazy var previewLayer: AVCaptureVideoPreviewLayer = {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }()

    func requestAccessAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted else { return }
                DispatchQueue.main.async { self?.configureAndStart() }
            }
        default:
            // TODO: surface a "camera access needed" state in the UI
            // pointing the user to Settings.
            break
        }
    }

    func stop() {
        session.stopRunning()
    }

    private func configureAndStart() {
        session.beginConfiguration()
        session.sessionPreset = .high

        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(output)

        session.commitConfiguration()
        videoQueue.async { [weak self] in
            self?.session.startRunning()
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastAnalysisTime >= minAnalysisInterval else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastAnalysisTime = now
        delegate?.cameraManager(self, didCapture: pixelBuffer)
    }
}
