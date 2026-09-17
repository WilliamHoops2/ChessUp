//
//  VisionCoordinator.swift
//  ChessUp
//
//  Created by William Silvano Angga on 12/09/26.
//
//  This is the piece that was missing: GameSession.humanMoveDetected(lanMove:)
//  existed, MoveDetector existed, CameraManager existed — but nothing
//  actually connected them. This owns that pipeline:
//
//    CameraManager -> BoardDetector -> MoveDetector -> GameSession
//
//  Kept separate from GameSession on purpose: GameSession is a pure
//  state machine with no AVFoundation/Vision dependencies, which makes
//  it trivial to unit test. VisionCoordinator is the "glue" layer that
//  owns those dependencies instead.
//
//  Defaults to MockBoardDetector so the whole game loop (this ->
//  MoveDetector -> GameSession -> ChessEngineManager -> SpeechAnnouncer)
//  can be exercised today via `simulateHumanMove(from:to:)`, without a
//  camera or trained vision model — exactly what ARCHITECTURE.md
//  recommends validating before wiring up the real camera pipeline.
//

import Foundation
import CoreVideo
import Combine

@MainActor
final class VisionCoordinator: ObservableObject {
    /// Surfaced for debug UI — e.g. disable the camera preview / show
    /// the move-simulator panel only when this is true.
    let isUsingMockDetector: Bool

    private let session: GameSession
    private let detector: BoardDetector
    private let moveDetector = MoveDetector()
    private let camera = CameraManager()

    /// Exposed so GameView can show a live preview (CameraPreviewView)
    /// of what the camera actually sees. VisionCoordinator itself never
    /// touches this — it consumes frames independently via the
    /// CameraManagerDelegate callback below — this is purely so the
    /// person holding the phone can see they've got the board framed.
    var cameraManager: CameraManager { camera }

    // MARK: - Debug overlay state
    // Surfaced for DebugOverlayView (see GameView) so the corners the
    // model is finding, and the same status messages that print to
    // the Xcode console, are visible on-screen too — useful when
    // testing untethered. None of this affects detection itself.

    /// The model's most recent corner guess, whether or not it was
    /// confident enough to accept as a real calibration. Nil until the
    /// first calibration attempt (or always nil for MockBoardDetector,
    /// which never calibrates against real corners).
    @Published private(set) var debugCorners: BoardCorners?
    @Published private(set) var debugCornerConfidences: [Float]?
    /// Pixel dimensions of the raw camera frame the corners above were
    /// found in — needed to map those frame-space points onto the
    /// preview view's own size/aspect-fill.
    @Published private(set) var debugImageSize: CGSize = .zero
    /// Mirrors CoreMLBoardDetector's console log, most recent line last.
    @Published private(set) var debugMessage: String = ""
    /// The warped top-down crop pieces-model actually analyzed, plus
    /// what it found there — nil/empty until the board is calibrated
    /// and at least one frame has reached piece detection.
    @Published private(set) var debugWarpedImage: CGImage?
    @Published private(set) var debugPieces: [PieceDetectionDebug] = []
    @Published private(set) var debugBoardGrid: BoardGrid = .uniform

    /// True once the board's corners are locked in — i.e. once it's
    /// meaningful to show a "board found, set up your pieces and tap
    /// Confirm" prompt. Deliberately separate from GameSession's own
    /// phase transition: corners lock in based purely on the board's
    /// physical edges being visible, whether or not pieces are on it
    /// yet, so this can go true well before the game is actually ready
    /// to start tracking moves.
    @Published private(set) var isReadyToConfirmSetup = false

    init(session: GameSession, detector: BoardDetector) {
        self.session = session
        self.detector = detector
        self.isUsingMockDetector = detector is MockBoardDetector
        camera.delegate = self

        if let coreMLDetector = detector as? CoreMLBoardDetector {
            coreMLDetector.onCalibrationAttempt = { [weak self] corners, confidences in
                self?.debugCorners = corners
                self?.debugCornerConfidences = confidences
            }
            coreMLDetector.onDebugMessage = { [weak self] message in
                self?.debugMessage = message
            }
            coreMLDetector.onFrameAnalysis = { [weak self] image, pieces in
                self?.debugWarpedImage = image
                self?.debugPieces = pieces
            }
            coreMLDetector.onGridRefined = { [weak self] grid in
                self?.debugBoardGrid = grid
            }
        }

        if isUsingMockDetector {
            // Nothing to calibrate against — unblock GameSession's
            // `.calibratingBoard` phase immediately, same as before
            // VisionCoordinator knew about calibration at all.
            session.boardCalibrated()
        }
    }

    /// Defaults to MockBoardDetector. Split out from the designated
    /// init above rather than using a default parameter value there —
    /// default-argument expressions are evaluated in a technically
    /// nonisolated context, but MockBoardDetector's implicit init is
    /// main-actor-isolated (this project sets
    /// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor), which is exactly
    /// the "main actor-isolated initializer called from a synchronous
    /// nonisolated context" warning. A convenience init's body runs
    /// with this class's own @MainActor isolation, so it doesn't hit
    /// that gap.
    convenience init(session: GameSession) {
        self.init(session: session, detector: MockBoardDetector())
    }

    /// Starts the real camera pipeline. No-op when using
    /// MockBoardDetector — there's nothing for a live camera feed to
    /// do there; moves are fed in via `simulateHumanMove(from:to:)`
    /// instead. With a CoreMLBoardDetector, this also drives the
    /// one-time board calibration (see `cameraManager(_:didCapture:)`)
    /// before per-frame piece detection kicks in.
    func start() {
        guard !isUsingMockDetector else { return }
        camera.requestAccessAndStart()
    }

    func stop() {
        camera.stop()
    }

    /// Call when the user taps a "my board is set up" confirm button.
    /// No-op for MockBoardDetector (nothing to confirm there — the mock
    /// path unblocks GameSession immediately in init, since it has no
    /// real board to wait on in the first place).
    func confirmBoardSetup() {
        (detector as? CoreMLBoardDetector)?.confirmPiecesReady()
    }

    /// Debug-only: simulate a human physically moving a piece, without
    /// a camera. `from`/`to` are algebraic squares, e.g. "e2", "e4".
    /// Feeds MoveDetector enough identical "stable" frames to satisfy
    /// its debounce requirement, exactly as consecutive real camera
    /// frames of a settled board would.
    func simulateHumanMove(from: String, to: String) {
        guard let mock = detector as? MockBoardDetector else {
            print("⚠️ simulateHumanMove(from:to:) requires a MockBoardDetector — this coordinator is using a different BoardDetector.")
            return
        }
        guard let fromSquare = Self.parseSquare(from), let toSquare = Self.parseSquare(to) else {
            print("⚠️ Invalid square name(s): \"\(from)\", \"\(to)\" — expected algebraic notation like \"e2\", \"e4\".")
            return
        }

        mock.simulateMove(from: fromSquare, to: toSquare)
        feedMockSnapshotUntilResolved(mock)
    }

    /// MoveDetector.requiredStableFrames is private, so this just feeds
    /// a generous number of identical frames rather than trying to
    /// mirror that exact constant — any count comfortably above it
    /// works, since ingest() is idempotent once already stable.
    private func feedMockSnapshotUntilResolved(_ mock: MockBoardDetector) {
        for _ in 0..<5 {
            if let lanMove = moveDetector.ingest(mock.currentSnapshot, oracle: session) {
                session.humanMoveDetected(lanMove: lanMove)
                return
            }
        }
    }

    private static func parseSquare(_ name: String) -> (file: Int, rank: Int)? {
        let files = Array("abcdefgh")
        guard name.count == 2,
              let fileChar = name.first,
              let rankChar = name.last,
              let fileIndex = files.firstIndex(of: fileChar),
              let rank = rankChar.wholeNumberValue,
              (1...8).contains(rank)
        else { return nil }
        return (fileIndex, rank - 1)
    }
}

extension VisionCoordinator: CameraManagerDelegate {
    // CameraManager calls this on its own background video queue (see
    // CameraManager's `videoQueue`), so this needs to hop to the main
    // actor before touching `detector`/`moveDetector`/`session` — all
    // of which are main-actor-isolated (GameSession is @MainActor,
    // and this class is too).
    //
    // `pixelBuffer` is a CVPixelBuffer (a Core Foundation / CoreVideo
    // type), which Apple hasn't marked Sendable, so capturing it
    // directly into the `Task { @MainActor in ... }` closure below
    // triggers a strict-concurrency warning. CVPixelBuffer is
    // reference-counted and safe to hand across threads in practice
    // (that's the whole point of AVCaptureVideoDataOutput handing them
    // to a delegate callback queue in the first place) — this is a
    // case where `nonisolated(unsafe)` is the accepted escape hatch
    // for a known-safe-but-unannotated system type, not a real data race.
    nonisolated func cameraManager(_ manager: CameraManager, didCapture pixelBuffer: CVPixelBuffer) {
        nonisolated(unsafe) let buffer = pixelBuffer
        Task { @MainActor in
            debugImageSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))

            if let coreMLDetector = detector as? CoreMLBoardDetector, !coreMLDetector.isCalibrated {
                // Only runs until locked in (see CoreMLBoardDetector's
                // multi-frame consensus process) — with the phone on a
                // tripod, the board's position is fixed once set up, so
                // there's nothing to gain from continuing to run corner
                // detection after that, and real cost (a wasted model
                // inference every single frame for the rest of the
                // session) to not stopping.
                // `calibrate` is `@discardableResult`, but that
                // attribute doesn't propagate through `try?` — `try?`
                // wraps the return value in a *new* Optional, and using
                // that standalone still triggers "result of 'try?' is
                // unused". Explicitly discarding makes the intent
                // clear: errors and the returned corners are both
                // handled via the onCalibrationAttempt/onDebugMessage
                // callbacks above, not the return value here.
                _ = try? coreMLDetector.calibrate(pixelBuffer: buffer)
                if coreMLDetector.isCalibrated {
                    // Corners locked — NOT the same as the game being
                    // ready to start (see isReadyToConfirmSetup's doc
                    // comment). This just unlocks the "tap Confirm once
                    // your pieces are set up" prompt; GameSession's
                    // phase advances separately, below, only once
                    // occupancy calibration has actually finished.
                    isReadyToConfirmSetup = true
                }
            }

            guard let observed = detector.detectBoardState(in: buffer) else { return }

            if let coreMLDetector = detector as? CoreMLBoardDetector, coreMLDetector.isFullyCalibrated {
                session.boardCalibrated() // no-ops after the first call
            }

            if let lanMove = moveDetector.ingest(observed, oracle: session) {
                let message = "\u{1F3AF} move detected: \(lanMove)"
                print("[ChessUp Vision] \(message)")
                debugMessage = message
                session.humanMoveDetected(lanMove: lanMove)
            }
        }
    }
}
