//
//  CoreMLBoardDetector.swift
//  ChessUp
//
//  Created by William Silvano Angga on 15/09/26.
//
//  Real vision pipeline. Board-corner detection uses a model converted
//  from github.com/Elucidation/chessdetect-tfjs (MIT license) — a
//  small (~300KB) U-Net++ that takes a 128x128 center-square crop and
//  outputs a segmentation mask + 4-channel corner heatmap.
//
//    chessboard-corners (U-Net++) -> board corners, used ONCE at
//                                     calibration time to build a
//                                     perspective warp (the board
//                                     doesn't move mid-game, only the
//                                     pieces do).
//    hand-model   (YOLOv11l)     -> filters out frames where a hand is
//                                    over the board mid-move.
//
//  Piece identification no longer uses a model at all — see
//  OccupancyClassifier.swift. The 12-class "pieces-model" YOLO has
//  been retired: since a real chess game always starts from the same
//  known position, and every move afterward is tracked by
//  GameSession/ChessKit (the actual source of truth for which piece —
//  pawn, knight, etc — sits where), the vision layer only ever needs
//  to answer a 3-class-per-square question (empty / white / black),
//  not a 12-class one. OccupancyClassifier answers that with a
//  self-calibrating color heuristic instead of a trained model —
//  simpler, and one less model to ship/convert/maintain.
//  `pieces-model.mlpackage` can be removed from the Xcode project;
//  nothing references it anymore.
//
//  Setup:
//   1. Drag `chessboard-corners.mlpackage` and `hand-model.mlpackage`
//      into the Xcode project (remove `pieces-model.mlpackage` and the
//      old `board-model.mlpackage` if either is still there — neither
//      is referenced by any code anymore).
//   2. Call `calibrate(pixelBuffer:)` once from a "line up the board"
//      screen before using this as your `BoardDetector`. Calibration
//      assumes the near edge of the frame (bottom, closest to the
//      player holding the phone) is White's back rank, AND that the
//      board is in the standard starting position at that exact
//      moment — OccupancyClassifier's self-calibration depends on
//      that being true. Swap `rank` for `7 - rank` in `detectBoardState`
//      if you calibrate from Black's side instead.
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
    private let ciContext = CIContext()
    private let occupancyClassifier: OccupancyClassifier

    /// Set once the multi-frame consensus process (see `calibrate`)
    /// completes. Nil until then. Deliberately stays nil rather than
    /// updating on every good frame the way it briefly did — with the
    /// phone on a tripod, the board's real position never changes
    /// after setup, so continuously re-running corner detection can
    /// only ever hurt: a later frame that's individually noisier (but
    /// still clears the confidence bar) can silently overwrite a
    /// genuinely good earlier read, causing the warp to drift even
    /// though the physical board hasn't moved at all. Averaging a
    /// handful of consecutive good frames once, then freezing, is both
    /// more accurate (averaging cancels out per-frame noise a single
    /// frame can't) and more stable (no drift after lock-in) than
    /// either "trust the very first good frame" or "keep recalibrating
    /// forever."
    private var boardCorners: BoardCorners?

    /// Accumulates consecutive frames that clear the confidence bar,
    /// on the way to `framesRequiredToLock`. Reset to empty on any
    /// frame that doesn't clear it — this counts *consecutive* good
    /// frames, not good frames total, so a momentary bad read (a hand
    /// passing through frame, motion blur while nudging the tripod
    /// into position) can't get averaged in alongside genuinely good
    /// ones.
    private var pendingCorners: [BoardCorners] = []
    /// How many consecutive good frames to average before locking in.
    /// At the ~2fps CameraManager throttles to, this is roughly a
    /// 2-2.5 second "hold it steady" window — long enough to average
    /// out noise, short enough not to feel like a wait.
    private let framesRequiredToLock = 5

    /// Refined 8x8 grid line positions within the warped board crop —
    /// see GridRefiner.swift. Recomputed alongside `boardCorners` on
    /// every accepted calibration frame; falls back to `.uniform`
    /// (naive /8 division) anywhere it hasn't been computed yet or a
    /// particular frame's warp wasn't suitable for refinement.
    private var boardGrid: BoardGrid = .uniform

    private let handConfidenceThreshold: Float = 0.65
    /// Each of the 4 corner-heatmap channels must clear this to accept
    /// a calibration frame. Real corners scored 0.4-0.8+ in testing;
    /// a corner clipped by the center-square crop (or just out of
    /// frame) scored as low as 0.19-0.25 — this threshold is set low
    /// enough to tolerate an imperfectly-centered shot while still
    /// rejecting a corner that's genuinely not visible.
    private let minCornerConfidence: Float = 0.15

    /// Fires on every calibration attempt — accepted or not — with the
    /// decoded corners and per-corner confidences, so a debug overlay
    /// can draw the model's current best guess even while calibration
    /// keeps failing. Set by whoever owns this detector (VisionCoordinator).
    var onCalibrationAttempt: ((BoardCorners, [Float]) -> Void)?

    /// Fires whenever `boardGrid` is recomputed (see GridRefiner.swift),
    /// so a debug overlay can draw the actual refined line positions
    /// instead of assuming a uniform 8x8 split.
    var onGridRefined: ((BoardGrid) -> Void)?

    /// Mirrors every `log(...)` call below to whoever's listening, so
    /// the same messages that show up in the Xcode console can also be
    /// shown on-screen (useful when testing without a cable attached).
    var onDebugMessage: ((String) -> Void)?

    /// Fires on every frame that reaches occupancy classification (i.e.
    /// once calibrated and no hand is blocking the view), with the
    /// warped top-down crop that was analyzed plus whatever occupied
    /// squares were found in it. Lets a debug view show ground truth
    /// for "is grid/occupancy detection working" independent of
    /// whether calibration's corners look right — a bad warp is
    /// immediately obvious once you can see the crop itself, not just
    /// infer it from corner coordinates.
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

    /// Runs one frame through the multi-frame consensus process:
    /// decode this frame's corners, and if they clear the confidence
    /// bar, add them to the running set of consecutive good frames.
    /// Once `framesRequiredToLock` consecutive good frames have
    /// accumulated, averages them into the final, permanent
    /// `boardCorners` and stops — see `boardCorners`'s doc comment for
    /// why locking permanently (rather than keeping this running every
    /// frame indefinitely) is the right call for a tripod-mounted phone.
    ///
    /// Returns the current best guess either way — the just-decoded
    /// frame's corners while still accumulating, or the final locked
    /// corners once locked — so a debug overlay always has something
    /// to draw. Only the locked case actually updates `boardCorners`/
    /// `isCalibrated`, though.
    @discardableResult
    func calibrate(pixelBuffer: CVPixelBuffer) throws -> BoardCorners {
        if let boardCorners {
            // Already locked. VisionCoordinator stops calling this
            // once `isCalibrated` is true, so this branch is normally
            // dead code — it's here as a safety net so calling this
            // again after lock-in is a harmless no-op rather than
            // silently re-triggering the whole averaging process.
            return boardCorners
        }

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

        // Report the attempt regardless of whether it's confident
        // enough to accept — a debug overlay wants to see the model's
        // current best guess even while calibration keeps failing.
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
        // A fresh lock-in means a fresh perspective warp, which means
        // OccupancyClassifier's sampled cell colors would no longer
        // line up with anything it calibrated against before.
        occupancyClassifier.invalidate()

        log("🔒 board locked in after \(framesRequiredToLock) consistent frames — corners \(locked). Corner detection won't run again this session — call `resetCalibration()` if the phone/board gets bumped.")

        // Refine the 8x8 grid using this locked-in warp — see
        // GridRefiner.swift. Best-effort: if the warp or render fails
        // here, boardGrid just stays whatever it was (.uniform on a
        // fresh detector), so a refinement hiccup never blocks
        // lock-in itself from succeeding.
        if let warped = PerspectiveWarp.warp(CIImage(cvPixelBuffer: pixelBuffer), corners: locked),
           let warpedBuffer = render(warped) {
            boardGrid = GridRefiner.refine(pixelBuffer: warpedBuffer)
            onGridRefined?(boardGrid)
        } else {
            log("⚠️ grid refinement skipped (warp/render failed) — using previous grid")
        }

        return locked
    }

    /// Averages a set of corner readings into one — reduces per-frame
    /// noise in a way no single frame's reading can, since detector
    /// noise on a genuinely stationary board tends to scatter roughly
    /// symmetrically around the true position rather than consistently
    /// erring the same direction.
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

    /// Clears the current lock-in (if any) and starts the multi-frame
    /// consensus process over from scratch. Not wired to any UI yet —
    /// here as a hook for a future "recalibrate" button (e.g. if the
    /// tripod or board gets bumped mid-session). Note that on its own
    /// this only affects CoreMLBoardDetector — GameSession's phase
    /// machinery would also need a way back into `.calibratingBoard`
    /// for a recalibrate button to make sense end-to-end; that's
    /// deliberately not wired up yet since nothing calls this method.
    func resetCalibration() {
        boardCorners = nil
        pendingCorners.removeAll()
        occupancyClassifier.invalidate()
        boardGrid = .uniform
        log("🔄 calibration reset — waiting for \(framesRequiredToLock) consecutive good frames")
    }

    /// Lets a calibration UI hand in user-adjusted corners (e.g. after
    /// the player drags them to line up with the physical board).
    func setCalibratedCorners(_ corners: BoardCorners) {
        boardCorners = corners
        occupancyClassifier.invalidate()
    }

    /// Call once the user explicitly confirms the board is fully set
    /// up (all 32 pieces in the standard starting position) and the
    /// phone is holding steady. This is deliberately NOT automatic:
    /// corner lock-in only depends on the board's physical edges being
    /// visible, which is true whether or not any pieces are on it yet
    /// — auto-triggering occupancy calibration right after corner
    /// lock-in risked calibrating against a half-set-up board if the
    /// player was still placing pieces at that exact moment. No-op if
    /// corners aren't locked yet (there's no warp to sample from) or
    /// if occupancy calibration is already done or already running.
    func confirmPiecesReady() {
        guard boardCorners != nil else {
            log("⚠️ confirmPiecesReady() called before the board itself was found — ignoring")
            return
        }
        guard !occupancyClassifier.isCalibrated, !occupancyClassifier.isCalibrationInProgress else { return }
        occupancyClassifier.beginCalibration()
        log("👍 setup confirmed — averaging several frames for the occupancy baseline")
    }

    /// True once BOTH the board's corners are locked in AND the
    /// occupancy classifier has a real baseline to classify against —
    /// i.e. the point at which the game can actually start tracking
    /// moves. `isCalibrated` alone (corners only) isn't enough for that.
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
        // Re-wrap from the rendered buffer (rather than reusing `warped`
        // directly) so downstream sampling works in a clean 0,0-origin
        // coordinate space matching the buffer's own dimensions —
        // `warped.extent` can have an arbitrary origin depending on how
        // CIPerspectiveCorrection placed it.
        let warpedImage = CIImage(cvPixelBuffer: warpedBuffer)

        // Always report the warped crop, even on paths that bail out
        // below without a BoardState — a debug view showing exactly
        // what's being analyzed is useful whether or not this
        // particular frame produced a usable result.
        let warpedCGImage = ciContext.createCGImage(warpedImage, from: warpedImage.extent)

        if let handConfidence = handConfidence(in: warpedBuffer), handConfidence >= handConfidenceThreshold {
            log("✋ hand over board (confidence \(String(format: "%.2f", handConfidence))) — skipping frame")
            if let warpedCGImage { onFrameAnalysis?(warpedCGImage, []) }
            return nil
        }

        // Once corners are locked, this stays safe to call every
        // frame regardless of occupancy-calibration status: it
        // accumulates calibration frames while that's in progress (see
        // below) and just returns nil the rest of the time until it's
        // confirmed and finished. Nothing here auto-starts occupancy
        // calibration anymore — see `confirmPiecesReady()`.
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

    /// DEBUG-only, tagged for easy filtering in the console. The
    /// message is an autoclosure so string interpolation work doesn't
    /// even happen in Release builds.
    private func log(_ message: @autoclosure () -> String) {
        let text = message()
        #if DEBUG
        print("[ChessUp Vision] \(text)")
        #endif
        onDebugMessage?(text)
    }
}

/// A single occupied-square detection on the warped top-down crop,
/// carried out to a debug view. `label` is "white" or "black" —
/// nothing more specific, since OccupancyClassifier deliberately never
/// determines piece kind. Not used by BoardDetector/GameSession at
/// all — purely for visualizing "what did occupancy detection
/// actually see".
struct PieceDetectionDebug {
    let label: String
    let confidence: Float
    /// Normalized, Vision convention (origin bottom-left, 0...1).
    let boundingBox: CGRect
}
