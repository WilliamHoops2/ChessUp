//
//  BoardState.swift
//  ChessUp
//
//  Created by William Silvano Angga on 12/09/26.
//
//  Represents what the camera/vision pipeline currently sees on the
//  physical board: which piece (if any) occupies each of the 64 squares.
//  This is deliberately decoupled from ChessKit's `Position` type —
//  vision output is "noisy" (a snapshot of reality), whereas a chess
//  `Position` is "authoritative" (a validated legal game state). We
//  diff BoardState snapshots to infer a move, then hand that move to
//  ChessKit to validate and apply.
//

import Foundation

enum PieceColor: String, Codable {
    case white
    case black
}

enum PieceKind: String, Codable, CaseIterable {
    case pawn, knight, bishop, rook, queen, king
}

struct DetectedPiece: Codable, Equatable {
    let color: PieceColor
    let kind: PieceKind
}

/// A single snapshot of the 64 squares, indexed a1...h8.
/// File 0 = a, File 7 = h. Rank 0 = rank 1, Rank 7 = rank 8.
struct BoardState: Equatable {
    /// squares[file][rank] — nil means empty square
    var squares: [[DetectedPiece?]]

    init() {
        squares = Array(repeating: Array(repeating: nil, count: 8), count: 8)
    }

    subscript(file: Int, rank: Int) -> DetectedPiece? {
        get { squares[file][rank] }
        set { squares[file][rank] = newValue }
    }

    /// Standard algebraic square, e.g. "e4"
    static func squareName(file: Int, rank: Int) -> String {
        let files = ["a", "b", "c", "d", "e", "f", "g", "h"]
        return "\(files[file])\(rank + 1)"
    }

    /// The standard starting position, useful for calibration and testing
    /// the pipeline without a camera.
    static var startingPosition: BoardState {
        var state = BoardState()
        let backRank: [PieceKind] = [.rook, .knight, .bishop, .queen, .king, .bishop, .knight, .rook]
        for file in 0..<8 {
            state[file, 0] = DetectedPiece(color: .white, kind: backRank[file])
            state[file, 1] = DetectedPiece(color: .white, kind: .pawn)
            state[file, 6] = DetectedPiece(color: .black, kind: .pawn)
            state[file, 7] = DetectedPiece(color: .black, kind: backRank[file])
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
