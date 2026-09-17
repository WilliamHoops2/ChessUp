//
//  BoardState.swift
//  ChessUp
//
//  Created by William Silvano Angga on 15/09/26.
//
//  Represents what the camera/vision pipeline currently sees on the
//  physical board: which color (if any) occupies each of the 64
//  squares. Deliberately does NOT track piece kind (pawn vs knight vs
//  queen etc) — only occupancy + color, a 3-class-per-square problem
//  rather than a 12-class one.
//
//  This is the core simplification: since a real chess game always
//  starts from the same known position, GameSession/ChessKit's Board
//  is the sole source of truth for WHICH piece is on a square — it
//  derives that from the starting position plus every legal move
//  played since. The vision layer's only job is noticing when a
//  square's occupant changed; MoveDetector cross-references those
//  changes against ChessKit's legal-move generator (via
//  MoveLegalityOracle) to figure out which move actually happened.
//
//  Deliberately decoupled from ChessKit's `Position` type for the same
//  reason as before — vision output is "noisy" (a snapshot of
//  reality), whereas a chess `Position` is "authoritative" (a
//  validated legal game state) — but reuses ChessKit's `Piece.Color`
//  directly rather than a separate app-defined color enum, since
//  that's the one piece of piece-identity vision genuinely does need
//  to track, and it's the same concept either way.
//

import Foundation
import ChessKit

enum Occupant: Equatable, Hashable {
    case empty
    case piece(Piece.Color)
}

/// A single snapshot of the 64 squares, indexed a1...h8.
/// File 0 = a, File 7 = h. Rank 0 = rank 1, Rank 7 = rank 8.
struct BoardState: Equatable {
    /// squares[file][rank]
    var squares: [[Occupant]]

    init() {
        squares = Array(repeating: Array(repeating: .empty, count: 8), count: 8)
    }

    subscript(file: Int, rank: Int) -> Occupant {
        get { squares[file][rank] }
        set { squares[file][rank] = newValue }
    }

    /// Standard algebraic square, e.g. "e4"
    static func squareName(file: Int, rank: Int) -> String {
        let files = ["a", "b", "c", "d", "e", "f", "g", "h"]
        return "\(files[file])\(rank + 1)"
    }

    /// The standard starting position, useful for calibration and testing
    /// the pipeline without a camera. Only colors are recorded — file 0
    /// (the back rank rook/knight/bishop/queen/king row) is
    /// indistinguishable from any other occupied square vision-wise,
    /// which is exactly the point.
    static var startingPosition: BoardState {
        var state = BoardState()
        for file in 0..<8 {
            state[file, 0] = .piece(.white)
            state[file, 1] = .piece(.white)
            state[file, 6] = .piece(.black)
            state[file, 7] = .piece(.black)
        }
        return state
    }

    /// Every square that differs between two snapshots, as (file, rank) pairs.
    static func diffSquares(from old: BoardState, to new: BoardState) -> [(file: Int, rank: Int)] {
        var changed: [(Int, Int)] = []
        for file in 0..<8 {
            for rank in 0..<8 {
                if old[file, rank] != new[file, rank] {
                    changed.append((file, rank))
                }
            }
        }
        return changed
    }
}
