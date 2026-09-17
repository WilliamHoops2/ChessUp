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
            let device = Self.pickCaptureDevice(),
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

        // CRITICAL: without this, the CVPixelBuffers handed to the
        // delegate stay in the camera sensor's native orientation
        // (landscape, e.g. 1920x1080) regardless of how the phone is
        // actually held — AVCaptureVideoPreviewLayer rotates its OWN
        // rendering for display independently, so the preview looks
        // correctly upright even while the buffers going to Vision/
        // CoreML are still sideways. That mismatch is what was causing
        // the corner model's output points, the perspective warp, and
        // the debug overlay to all disagree about coordinate space.
        // Rotating here means every downstream consumer — corner
        // detection, the warp, the debug overlay's imageSize — works
        // in the same portrait pixel space the user actually sees.
        // This assumes the phone is held in portrait for the
        // overhead-board shot described in the app spec; if you ever
        // support landscape mounting too, this angle needs to track
        // the device/interface orientation instead of being hardcoded.
        //
        // Only the iOS 17+ `videoRotationAngle` API is used here (no
        // `videoOrientation` fallback) — the project has no deployment
        // target override, so it inherits Xcode 26.6's modern default,
        // well above 17. `videoOrientation`/`isVideoOrientationSupported`
        // are deprecated as of iOS 17, and referencing them at all
        // triggers a deprecation warning regardless of which branch of
        // an `#available` check they're in — `#available` only guards
        // whether an API is *callable*, not whether the compiler warns
        // about it being deprecated. If you ever do lower the
        // deployment target below 17, this silently no-ops there
        // instead of rotating, which is worth knowing rather than
        // reaching for the deprecated fallback again.
        if #available(iOS 17.0, *),
           let connection = output.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }

        session.commitConfiguration()
        videoQueue.async { [weak self] in
            self?.session.startRunning()
        }
    }

    /// Prefers the ultra-wide ("0.5x") lens over the standard wide
    /// ("1x") lens. This is a framing fix, not a quality tweak: at 1x
    /// from a normal phone-propped-above-the-board distance, the
    /// board can easily fill more than the frame's width/height —
    /// which was cutting off the h-file and the bottom-right corner
    /// entirely in testing, silently undercounting occupied squares
    /// (they were never in the shot at all, not misclassified). The
    /// ultra-wide lens's wider field of view lets the whole board fit
    /// from the same physical distance instead of requiring the user
    /// to prop the phone further away (often impractical indoors).
    /// Falls back to the standard wide lens on hardware without an
    /// ultra-wide (e.g. iPhone SE) rather than failing to start at all.
    private static func pickCaptureDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
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
