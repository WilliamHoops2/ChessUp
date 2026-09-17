//
//  BoardDetector.swift
//  ChessUp
//
//  Created by William Silvano Angga on 15/09/26.
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

    func reset() {
        currentState = .startingPosition
    }

    /// Debug-only hook: simulate a human physically moving a piece —
    /// covers both plain moves and direct captures (a capture is just
    /// a move onto an already-occupied destination; whatever was there
    /// is simply overwritten, exactly as it would be on a real board).
    /// Does NOT by itself simulate castling or en passant, since those
    /// change more than 2 squares atomically — see the dedicated
    /// helpers below for those.
    func simulateMove(from: (file: Int, rank: Int), to: (file: Int, rank: Int)) {
        let occupant = currentState[from.file, from.rank]
        guard occupant != .empty else { return }
        currentState[from.file, from.rank] = .empty
        currentState[to.file, to.rank] = occupant
    }

    /// Debug-only hook: simulate castling, moving the king and rook
    /// together in one atomic change. MoveDetector specifically looks
    /// for a 4-square diff to recognize castling — two separate
    /// `simulateMove` calls (with stable frames fed in between) would
    /// instead look like two independent normal moves.
    func simulateCastle(
        kingFrom: (file: Int, rank: Int), kingTo: (file: Int, rank: Int),
        rookFrom: (file: Int, rank: Int), rookTo: (file: Int, rank: Int)
    ) {
        let king = currentState[kingFrom.file, kingFrom.rank]
        let rook = currentState[rookFrom.file, rookFrom.rank]
        guard king != .empty, rook != .empty else { return }
        currentState[kingFrom.file, kingFrom.rank] = .empty
        currentState[rookFrom.file, rookFrom.rank] = .empty
        currentState[kingTo.file, kingTo.rank] = king
        currentState[rookTo.file, rookTo.rank] = rook
    }

    /// Debug-only hook: simulate an en passant capture — the moving
    /// pawn's origin and destination, plus the captured pawn's square
    /// (adjacent to origin, same file as destination), all changing
    /// atomically. Mirrors MoveDetector's 3-square en passant pattern.
    func simulateEnPassant(
        from: (file: Int, rank: Int), to: (file: Int, rank: Int),
        capturedPawnAt captured: (file: Int, rank: Int)
    ) {
        let pawn = currentState[from.file, from.rank]
        guard pawn != .empty, currentState[captured.file, captured.rank] != .empty else { return }
        currentState[from.file, from.rank] = .empty
        currentState[captured.file, captured.rank] = .empty
        currentState[to.file, to.rank] = pawn
    }
}
