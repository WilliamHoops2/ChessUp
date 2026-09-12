//
//  BoardDetector.swift
//  ChessUp
//
//  Created by William Silvano Angga on 12/09/26.
//
//  `MockBoardDetector` lets you build and test GameSession, the engine
//  integration, speech, and the whole UI flow without a camera or a
//  trained model. The real implementation, `CoreMLBoardDetector`, is
//  in CoreMLBoardDetector.swift (+ BoardSegmentation.swift for the
//  board-corner detection and perspective-warp helpers it depends on).
//

import CoreVideo

protocol BoardDetector {
    /// Returns nil if the detector isn't confident enough yet (e.g. a
    /// hand is over the board, lighting is bad, or the board isn't
    /// fully in frame). Callers should just wait for the next frame
    /// rather than treating nil as "empty board".
    func detectBoardState(in pixelBuffer: CVPixelBuffer) -> BoardState?
}

/// Lets you build and test GameSession, MoveDetector, the engine
/// integration, speech, and the whole UI flow without a trained model.
/// Feed it moves manually (e.g. from a debug panel) to simulate the
/// camera seeing a physical move happen.
final class MockBoardDetector: BoardDetector {
    private var currentState = BoardState.startingPosition

    /// Exposed so VisionCoordinator's debug move-simulator can feed the
    /// current mock snapshot into MoveDetector directly, without going
    /// through the camera/detectBoardState path.
    var currentSnapshot: BoardState { currentState }

    func detectBoardState(in pixelBuffer: CVPixelBuffer) -> BoardState? {
        currentState
    }

    /// Debug-only hook: simulate a human physically moving a piece.
    func simulateMove(from: (file: Int, rank: Int), to: (file: Int, rank: Int)) {
        guard let piece = currentState[from.file, from.rank] else { return }
        currentState[from.file, from.rank] = nil
        currentState[to.file, to.rank] = piece
    }
}
