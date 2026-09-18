//
//  BoardDetector.swift
//  ChessUp
//
//  Created by William Silvano Angga on 15/09/26.
//

import CoreVideo

protocol BoardDetector {
    func detectBoardState(in pixelBuffer: CVPixelBuffer) -> BoardState?
}

final class MockBoardDetector: BoardDetector {
    private var currentState = BoardState.startingPosition

    var currentSnapshot: BoardState { currentState }

    func detectBoardState(in pixelBuffer: CVPixelBuffer) -> BoardState? {
        currentState
    }

    func reset() {
        currentState = .startingPosition
    }

    func simulateMove(from: (file: Int, rank: Int), to: (file: Int, rank: Int)) {
        let occupant = currentState[from.file, from.rank]
        guard occupant != .empty else { return }
        currentState[from.file, from.rank] = .empty
        currentState[to.file, to.rank] = occupant
    }

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
