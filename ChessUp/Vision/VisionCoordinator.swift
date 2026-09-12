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

    init(session: GameSession, detector: BoardDetector) {
        self.session = session
        self.detector = detector
        self.isUsingMockDetector = detector is MockBoardDetector
        camera.delegate = self

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
            if let lanMove = moveDetector.ingest(mock.currentSnapshot) {
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
            // One-time calibration: run board-model until it finds the
            // board, then lock in the corners for every future frame
            // (see CoreMLBoardDetector.calibrate). A future
            // BoardCalibrationView can call `setCalibratedCorners`
            // directly instead, once the drag-to-adjust overlay exists
            // (see the TODO in GameView) — this auto-calibration is a
            // reasonable default in the meantime.
            if let coreMLDetector = detector as? CoreMLBoardDetector, !coreMLDetector.isCalibrated {
                do {
                    try coreMLDetector.calibrate(pixelBuffer: buffer)
                    session.boardCalibrated()
                } catch {
                    // CoreMLBoardDetector already logs the specific
                    // reason (see its `log(...)` calls) — expected to
                    // fail repeatedly while lining up the board, so no
                    // need to double-log here.
                }
                return
            }

            guard let observed = detector.detectBoardState(in: buffer) else { return }
            if let lanMove = moveDetector.ingest(observed) {
                print("[ChessUp Vision] \u{1F3AF} move detected: \(lanMove)")
                session.humanMoveDetected(lanMove: lanMove)
            }
        }
    }
}
