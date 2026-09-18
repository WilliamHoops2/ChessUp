//
//  CoreMLBoardDetector.swift
//  ChessUp
//
//  Created by William Silvano Angga on 15/09/26.
//

import CoreVideo
import CoreImage
import CoreML
import Vision

final class CoreMLBoardDetector: BoardDetector {

    enum SetupError: Error {
        case modelNotFound(String)
    }

    private let cornersModel: VNCoreMLModel
    private let handModel: VNCoreMLModel
    private let ciContext = CIContext()
    private let occupancyClassifier: OccupancyClassifier

    private var boardCorners: BoardCorners?

    private var pendingCorners: [BoardCorners] = []
    private let framesRequiredToLock = 5

    private var boardGrid: BoardGrid = .uniform

    private let handConfidenceThreshold: Float = 0.65
    private let minCornerConfidence: Float = 0.15

    var onCalibrationAttempt: ((BoardCorners, [Float]) -> Void)?

    var onGridRefined: ((BoardGrid) -> Void)?

    var onDebugMessage: ((String) -> Void)?

    var onFrameAnalysis: ((CGImage, [PieceDetectionDebug]) -> Void)?

    init() throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all

        func loadModel(_ name: String) throws -> VNCoreMLModel {
            guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else {
                throw SetupError.modelNotFound(name)
            }
            return try VNCoreMLModel(for: try MLModel(contentsOf: url, configuration: config))
        }

        cornersModel = try loadModel("chessboard-corners")
        handModel = try loadModel("hand-model")
        occupancyClassifier = OccupancyClassifier(ciContext: ciContext)
    }

    // MARK: - Calibration

    @discardableResult
    func calibrate(pixelBuffer: CVPixelBuffer) throws -> BoardCorners {
        if let boardCorners {
            return boardCorners
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let side = CGFloat(min(width, height))
        let cropRect = CGRect(
            x: (CGFloat(width) - side) / 2,
            y: (CGFloat(height) - side) / 2,
            width: side,
            height: side
        )

        let request = VNCoreMLRequest(model: cornersModel)
        request.imageCropAndScaleOption = .centerCrop
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try handler.perform([request])

        guard let results = request.results as? [VNCoreMLFeatureValueObservation] else {
            log("⚠️ chessboard-corners model returned an unexpected result type")
            throw BoardSegmentationError.unexpectedOutputShape
        }
        guard
            let cornerHeatmap = results.first(where: { $0.featureName == "Identity" })?.featureValue.multiArrayValue,
            let segmentation = results.first(where: { $0.featureName == "Identity_1" })?.featureValue.multiArrayValue
        else {
            log("⚠️ chessboard-corners model produced no usable output for this frame")
            throw BoardSegmentationError.noDetection
        }

        let result: BoardDetectionResult
        do {
            result = try CornerHeatmapDecoder.decode(
                cornerHeatmap: cornerHeatmap,
                segmentation: segmentation,
                cropRect: cropRect
            )
        } catch {
            log("❌ calibration frame rejected: \(error)")
            throw error
        }

        onCalibrationAttempt?(result.corners, result.cornerConfidences)

        let confStr = result.cornerConfidences.map { String(format: "%.2f", $0) }.joined(separator: ",")
        guard result.cornerConfidences.allSatisfy({ $0 >= minCornerConfidence }) else {
            pendingCorners.removeAll()
            log("❌ corner confidence too low [\(confStr)] (need ≥\(minCornerConfidence) on all 4) — segmentation \(String(format: "%.3f", result.segmentationConfidence)); consensus streak reset")
            throw BoardSegmentationError.noDetection
        }

        pendingCorners.append(result.corners)
        log("✅ good calibration frame \(pendingCorners.count)/\(framesRequiredToLock) — corner confidences [\(confStr)], corners \(result.corners)")

        guard pendingCorners.count >= framesRequiredToLock else {
            return result.corners
        }

        let locked = Self.average(pendingCorners)
        pendingCorners.removeAll()
        boardCorners = locked
        occupancyClassifier.invalidate()

        log("🔒 board locked in after \(framesRequiredToLock) consistent frames — corners \(locked). Corner detection won't run again this session — call `resetCalibration()` if the phone/board gets bumped.")

        if let warped = PerspectiveWarp.warp(CIImage(cvPixelBuffer: pixelBuffer), corners: locked),
           let warpedBuffer = render(warped) {
            boardGrid = GridRefiner.refine(pixelBuffer: warpedBuffer)
            onGridRefined?(boardGrid)
        } else {
            log("⚠️ grid refinement skipped (warp/render failed) — using previous grid")
        }

        return locked
    }

    private static func average(_ corners: [BoardCorners]) -> BoardCorners {
        func avg(_ points: [CGPoint]) -> CGPoint {
            let n = CGFloat(points.count)
            return CGPoint(
                x: points.reduce(0) { $0 + $1.x } / n,
                y: points.reduce(0) { $0 + $1.y } / n
            )
        }
        return BoardCorners(
            topLeft: avg(corners.map(\.topLeft)),
            topRight: avg(corners.map(\.topRight)),
            bottomRight: avg(corners.map(\.bottomRight)),
            bottomLeft: avg(corners.map(\.bottomLeft))
        )
    }

    func resetCalibration() {
        boardCorners = nil
        pendingCorners.removeAll()
        occupancyClassifier.invalidate()
        boardGrid = .uniform
        log("🔄 calibration reset — waiting for \(framesRequiredToLock) consecutive good frames")
    }

    func setCalibratedCorners(_ corners: BoardCorners) {
        boardCorners = corners
        occupancyClassifier.invalidate()
    }

    func confirmPiecesReady() {
        guard boardCorners != nil else {
            log("⚠️ confirmPiecesReady() called before the board itself was found — ignoring")
            return
        }
        guard !occupancyClassifier.isCalibrated, !occupancyClassifier.isCalibrationInProgress else { return }
        occupancyClassifier.beginCalibration()
        log("👍 setup confirmed — averaging several frames for the occupancy baseline")
    }

    var isFullyCalibrated: Bool { boardCorners != nil && occupancyClassifier.isCalibrated }

    var isCalibrated: Bool { boardCorners != nil }

    // MARK: - BoardDetector

    func detectBoardState(in pixelBuffer: CVPixelBuffer) -> BoardState? {
        guard let corners = boardCorners else { return nil }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let warped = PerspectiveWarp.warp(ciImage, corners: corners) else {
            log("⚠️ perspective warp failed")
            return nil
        }
        guard let warpedBuffer = render(warped) else {
            log("⚠️ failed to render warped image to a pixel buffer")
            return nil
        }
        let warpedImage = CIImage(cvPixelBuffer: warpedBuffer)

        let warpedCGImage = ciContext.createCGImage(warpedImage, from: warpedImage.extent)

        if let handConfidence = handConfidence(in: warpedBuffer), handConfidence >= handConfidenceThreshold {
            log("✋ hand over board (confidence \(String(format: "%.2f", handConfidence))) — skipping frame")
            if let warpedCGImage { onFrameAnalysis?(warpedCGImage, []) }
            return nil
        }

        if occupancyClassifier.isCalibrationInProgress {
            let finished = occupancyClassifier.accumulateCalibrationFrame(warpedImage: warpedImage, grid: boardGrid)
            log(finished ? "🎨 occupancy baseline locked in" : "🎨 accumulating occupancy calibration frame")
        }

        guard let (state, debugPieces) = occupancyClassifier.classify(warpedImage: warpedImage, grid: boardGrid) else {
            if let warpedCGImage { onFrameAnalysis?(warpedCGImage, []) }
            return nil
        }

        if let warpedCGImage {
            onFrameAnalysis?(warpedCGImage, debugPieces)
        }

        log("♟️ \(debugPieces.count) occupied square(s) detected")
        return state
    }

    // MARK: - Hand check

    private func handConfidence(in pixelBuffer: CVPixelBuffer) -> Float? {
        let request = VNCoreMLRequest(model: handModel)
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do {
            try handler.perform([request])
        } catch {
            log("⚠️ hand-model request failed: \(error)")
            return nil
        }
        guard let results = request.results as? [VNRecognizedObjectObservation] else { return nil }
        return results.map(\.confidence).max()
    }

    // MARK: - Helpers

    private func render(_ image: CIImage) -> CVPixelBuffer? {
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as CFDictionary

        var pixelBuffer: CVPixelBuffer?
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)
        guard width > 0, height > 0 else { return nil }

        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &pixelBuffer)
        guard let buffer = pixelBuffer else { return nil }
        ciContext.render(image, to: buffer)
        return buffer
    }

    private func log(_ message: @autoclosure () -> String) {
        let text = message()
        #if DEBUG
        print("[ChessUp Vision] \(text)")
        #endif
        onDebugMessage?(text)
    }
}

struct PieceDetectionDebug {
    let label: String
    let confidence: Float
    let boundingBox: CGRect
}
