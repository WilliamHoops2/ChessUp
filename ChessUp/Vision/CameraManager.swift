//
//  CameraManager.swift
//  ChessUp
//
//  Created by William Silvano Angga on 12/09/26.
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

    private var lastAnalysisTime: CFAbsoluteTime = 0
    private let minAnalysisInterval: CFAbsoluteTime = 0.5

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
