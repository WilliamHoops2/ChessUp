//
//  BoardState.swift
//  ChessUp
//
//  Created by William Silvano Angga on 15/09/26.
//

import Foundation
import ChessKit

enum Occupant: Equatable, Hashable {
    case empty
    case piece(Piece.Color)
}

struct BoardState: Equatable {
    var squares: [[Occupant]]

    init() {
        squares = Array(repeating: Array(repeating: .empty, count: 8), count: 8)
    }

    subscript(file: Int, rank: Int) -> Occupant {
        get { squares[file][rank] }
        set { squares[file][rank] = newValue }
    }

    static func squareName(file: Int, rank: Int) -> String {
        let files = ["a", "b", "c", "d", "e", "f", "g", "h"]
        return "\(files[file])\(rank + 1)"
    }

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
