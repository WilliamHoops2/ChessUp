//
//  VisionCoordinator.swift
//  ChessUp
//
//  Created by William Silvano Angga on 12/09/26.
//

import Foundation
import CoreVideo
import Combine

@MainActor
final class VisionCoordinator: ObservableObject {
    let isUsingMockDetector: Bool

    private let session: GameSession
    private let detector: BoardDetector
    private let moveDetector = MoveDetector()
    private let camera = CameraManager()

    var cameraManager: CameraManager { camera }

    // MARK: - Debug overlay state
    @Published private(set) var debugCorners: BoardCorners?
    @Published private(set) var debugCornerConfidences: [Float]?
    @Published private(set) var debugImageSize: CGSize = .zero
    @Published private(set) var debugMessage: String = ""
    @Published private(set) var debugWarpedImage: CGImage?
    @Published private(set) var debugPieces: [PieceDetectionDebug] = []
    @Published private(set) var debugBoardGrid: BoardGrid = .uniform

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
            session.boardCalibrated()
        }
    }

    convenience init(session: GameSession) {
        self.init(session: session, detector: MockBoardDetector())
    }

    func start() {
        guard !isUsingMockDetector else { return }
        camera.requestAccessAndStart()
    }

    func stop() {
        camera.stop()
    }

    func confirmBoardSetup() {
        (detector as? CoreMLBoardDetector)?.confirmPiecesReady()
    }

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
    nonisolated func cameraManager(_ manager: CameraManager, didCapture pixelBuffer: CVPixelBuffer) {
        nonisolated(unsafe) let buffer = pixelBuffer
        Task { @MainActor in
            debugImageSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))

            if let coreMLDetector = detector as? CoreMLBoardDetector, !coreMLDetector.isCalibrated {
                _ = try? coreMLDetector.calibrate(pixelBuffer: buffer)
                if coreMLDetector.isCalibrated {
                    isReadyToConfirmSetup = true
                }
            }

            guard let observed = detector.detectBoardState(in: buffer) else { return }

            if let coreMLDetector = detector as? CoreMLBoardDetector, coreMLDetector.isFullyCalibrated {
                session.boardCalibrated()
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
