//
//  CoreMLBoardDetector.swift
//  ChessUp
//
//  Real vision pipeline. Board-corner detection uses a model converted
//  from github.com/Elucidation/chessdetect-tfjs (MIT license) — a
//  small (~300KB) U-Net++ that takes a 128x128 center-square crop and
//  outputs a segmentation mask + 4-channel corner heatmap. Piece and
//  hand detection still use the two YOLOv11 models converted from
//  github.com/oliverfrost1/chess-video-move-detection (MIT license) —
//  those were never the problem; only the old board-model (which
//  scored 0.11-0.19 confidence on real photos of this board, versus
//  this model's 0.9998-1.0 segmentation / 0.4-0.8+ corner confidence
//  on the same photos) got replaced.
//
//    chessboard-corners (U-Net++) -> board corners, used ONCE at
//                                     calibration time to build a
//                                     perspective warp (the board
//                                     doesn't move mid-game, only the
//                                     pieces do).
//    pieces-model (YOLOv11l)     -> the 12 piece classes, run on every
//                                    warped frame.
//    hand-model   (YOLOv11l)     -> filters out frames where a hand is
//                                    over the board mid-move.
//
//  Setup:
//   1. Drag `chessboard-corners.mlpackage`, `pieces-model.mlpackage`,
//      and `hand-model.mlpackage` into the Xcode project (remove the
//      old `board-model.mlpackage` if it's still there — it's no
//      longer referenced by any code).
//   2. Call `calibrate(pixelBuffer:)` once from a "line up the board"
//      screen before using this as your `BoardDetector`. Calibration
//      assumes the near edge of the frame (bottom, closest to the
//      player holding the phone) is White's back rank — swap `rank`
//      for `7 - rank` in `detectPieces` if you calibrate from Black's
//      side instead.
//   3. Frame the board so it fits within a CENTER SQUARE of the shot —
//      this model's own preprocessing center-crops to a square before
//      resizing, so a corner sitting outside that square (e.g. a very
//      wide/tall aspect framing) never reaches the model at all. See
//      BoardSegmentation.swift for details.
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
    private let piecesModel: VNCoreMLModel
    private let ciContext = CIContext()

    /// Set once via `calibrate(pixelBuffer:)` or `setCalibratedCorners(_:)`.
    private var boardCorners: BoardCorners?

    private let pieceConfidenceThreshold: Float = 0.5
    private let handConfidenceThreshold: Float = 0.65
    /// Each of the 4 corner-heatmap channels must clear this to accept
    /// a calibration frame. Real corners scored 0.4-0.8+ in testing;
    /// a corner clipped by the center-square crop (or just out of
    /// frame) scored as low as 0.19-0.25 — this threshold is set low
    /// enough to tolerate an imperfectly-centered shot while still
    /// rejecting a corner that's genuinely not visible.
    private let minCornerConfidence: Float = 0.15

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
        piecesModel = try loadModel("pieces-model")
    }

    // MARK: - Calibration

    @discardableResult
    func calibrate(pixelBuffer: CVPixelBuffer) throws -> BoardCorners {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        // Matches Vision's own `.centerCrop` cropping exactly: crop the
        // longer dimension symmetrically down to a centered square.
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

        do {
            let result = try CornerHeatmapDecoder.decode(
                cornerHeatmap: cornerHeatmap,
                segmentation: segmentation,
                cropRect: cropRect,
                minCornerConfidence: minCornerConfidence
            )
            let confStr = result.cornerConfidences.map { String(format: "%.2f", $0) }.joined(separator: ",")
            log("✅ board calibrated — corner confidences [\(confStr)], segmentation \(String(format: "%.3f", result.segmentationConfidence)), corners \(result.corners)")
            boardCorners = result.corners
            return result.corners
        } catch {
            log("❌ calibration frame rejected: \(error)")
            throw error
        }
    }

    /// Lets a calibration UI hand in user-adjusted corners (e.g. after
    /// the player drags them to line up with the physical board).
    func setCalibratedCorners(_ corners: BoardCorners) {
        boardCorners = corners
    }

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

        if let handConfidence = handConfidence(in: warpedBuffer), handConfidence >= handConfidenceThreshold {
            log("✋ hand over board (confidence \(String(format: "%.2f", handConfidence))) — skipping frame")
            return nil
        }

        guard let pieces = detectPieces(in: warpedBuffer) else { return nil }

        var state = BoardState()
        for piece in pieces {
            state[piece.file, piece.rank] = piece.detected
        }
        log("♟️ \(pieces.count) piece(s) detected")
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

    // MARK: - Piece detection + grid mapping

    private struct MappedPiece {
        let file: Int
        let rank: Int
        let detected: DetectedPiece
    }

    private func detectPieces(in pixelBuffer: CVPixelBuffer) -> [MappedPiece]? {
        let request = VNCoreMLRequest(model: piecesModel)
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do {
            try handler.perform([request])
        } catch {
            log("⚠️ pieces-model request failed: \(error)")
            return nil
        }
        guard let results = request.results as? [VNRecognizedObjectObservation] else {
            log("⚠️ pieces-model returned an unexpected result type")
            return []
        }

        let mapped = results.compactMap { observation -> MappedPiece? in
            guard
                let top = observation.labels.first,
                top.confidence >= pieceConfidenceThreshold,
                let detected = Self.piece(for: top.identifier)
            else { return nil }

            // Vision bounding boxes are normalized with origin
            // bottom-left. The warped image is a top-down view of the
            // full board, so the box center maps directly onto one of
            // the 8x8 grid cells.
            let center = observation.boundingBox.center
            let file = min(7, max(0, Int(center.x * 8)))
            let rank = min(7, max(0, Int(center.y * 8)))
            return MappedPiece(file: file, rank: rank, detected: detected)
        }

        if results.count != mapped.count {
            log("   pieces-model raw detections: \(results.count), kept after confidence/label filter: \(mapped.count)")
        }
        return mapped
    }

    private static func piece(for label: String) -> DetectedPiece? {
        let parts = label.split(separator: "-")
        guard parts.count == 2 else { return nil }
        let color: PieceColor = parts[0] == "white" ? .white : .black
        let kind: PieceKind
        switch parts[1] {
        case "pawn": kind = .pawn
        case "knight": kind = .knight
        case "bishop": kind = .bishop
        case "rook": kind = .rook
        case "queen": kind = .queen
        case "king": kind = .king
        default: return nil
        }
        return DetectedPiece(color: color, kind: kind)
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

    /// DEBUG-only, tagged for easy filtering in the console. The
    /// message is an autoclosure so string interpolation work doesn't
    /// even happen in Release builds.
    private func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[ChessUp Vision] \(message())")
        #endif
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
