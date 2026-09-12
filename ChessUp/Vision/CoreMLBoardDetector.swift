//
//  CoreMLBoardDetector.swift
//  ChessUp
//
//  Created by William Silvano Angga on 12/09/26.
//
//  Real vision pipeline, built on three models converted from
//  github.com/oliverfrost1/chess-video-move-detection (MIT license):
//
//    board-model  (YOLOv11m-seg) -> board polygon, used ONCE at
//                                    calibration time to build a
//                                    perspective warp (the board
//                                    doesn't move mid-game, only the
//                                    pieces do).
//    pieces-model (YOLOv11l)     -> the 12 piece classes, run on every
//                                    warped frame.
//    hand-model   (YOLOv11l)     -> filters out frames where a hand is
//                                    over the board mid-move.
//
//  Setup:
//   1. Drag `board-model.mlpackage`, `pieces-model.mlpackage`, and
//      `hand-model.mlpackage` into the Xcode project (Xcode compiles
//      each to a `.mlmodelc` in the app bundle automatically).
//   2. Call `calibrate(pixelBuffer:)` once from a "line up the board"
//      screen (matches the board-calibration overlay already planned
//      in ARCHITECTURE.md) before using this as your `BoardDetector`.
//      Calibration assumes the near edge of the frame (bottom, closest
//      to the player holding the phone) is White's back rank — swap
//      `rank` for `7 - rank` in `detectPieces` if you calibrate from
//      Black's side instead.
//

import CoreVideo
import CoreImage
import CoreML
import Vision

final class CoreMLBoardDetector: BoardDetector {

    enum SetupError: Error {
        case modelNotFound(String)
    }

    private let boardModel: MLModel
    private let handModel: VNCoreMLModel
    private let piecesModel: VNCoreMLModel
    private let ciContext = CIContext()

    /// Output feature names for `boardModel`, resolved once from its
    /// spec rather than hardcoded — Core ML autogenerates names like
    /// "var_1605" during conversion, and they can differ between
    /// export runs.
    private lazy var boardOutputNames: (raw: String, proto: String)? = {
        var raw: String?
        var proto: String?
        for (name, desc) in boardModel.modelDescription.outputDescriptionsByName {
            guard let shape = desc.multiArrayConstraint?.shape.map({ $0.intValue }) else { continue }
            if shape.count == 3 { raw = name }      // [1, 37, 8400]
            if shape.count == 4 { proto = name }    // [1, 32, 160, 160]
        }
        guard let raw, let proto else { return nil }
        return (raw, proto)
    }()

    /// Set once via `calibrate(pixelBuffer:)` or `setCalibratedCorners(_:)`.
    /// `detectBoardState` returns nil (i.e. "not confident yet") until
    /// this is set, same as it would for a bad frame.
    private var boardCorners: BoardCorners?

    private let pieceConfidenceThreshold: Float = 0.5
    private let handConfidenceThreshold: Float = 0.65

    init() throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all

        func modelURL(_ name: String) throws -> URL {
            guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else {
                throw SetupError.modelNotFound(name)
            }
            return url
        }

        boardModel = try MLModel(contentsOf: try modelURL("board-model"), configuration: config)
        handModel = try VNCoreMLModel(for: try MLModel(contentsOf: try modelURL("hand-model"), configuration: config))
        piecesModel = try VNCoreMLModel(for: try MLModel(contentsOf: try modelURL("pieces-model"), configuration: config))
    }

    // MARK: - Calibration

    @discardableResult
    func calibrate(pixelBuffer: CVPixelBuffer) throws -> BoardCorners {
        guard let (rawName, protoName) = boardOutputNames else {
            log("⚠️ board-model outputs didn't match what we expected (need one 3-D and one 4-D output) — check the export")
            throw BoardSegmentationError.unexpectedOutputShape
        }
        let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: pixelBuffer)])
        let output = try boardModel.prediction(from: input)

        guard
            let raw = output.featureValue(for: rawName)?.multiArrayValue,
            let proto = output.featureValue(for: protoName)?.multiArrayValue
        else {
            log("⚠️ board-model produced no usable output for this frame")
            throw BoardSegmentationError.noDetection
        }

        do {
            let result = try BoardSegmentationDecoder.decode(raw: raw, proto: proto)
            log("✅ board calibrated — confidence \(String(format: "%.2f", result.confidence)), corners \(result.corners)")
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
