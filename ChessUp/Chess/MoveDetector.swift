//
//  MoveDetector.swift
//  ChessUp
//
//  Created by William Silvano Angga on 15/09/26.
//
///still not working

import Foundation
import ChessKit

protocol MoveLegalityOracle {
    var sideToMove: Piece.Color { get }
    func legalDestinations(from square: Square) -> [Square]
    func isPawn(at square: Square) -> Bool
}

final class MoveDetector {
    private var lastStable: BoardState = .startingPosition

    private var recentFrames: [BoardState] = []
    private let windowSize = 5
    private var lastEvaluatedComposite: BoardState?

    func ingest(_ observed: BoardState, oracle: MoveLegalityOracle) -> String? {
        recentFrames.append(observed)
        if recentFrames.count > windowSize {
            recentFrames.removeFirst()
        }
        guard recentFrames.count == windowSize else { return nil }

        let composite = Self.majorityVote(recentFrames)
        guard composite != lastEvaluatedComposite else { return nil }
        lastEvaluatedComposite = composite
        guard composite != lastStable else { return nil }

        defer { lastStable = composite }
        return resolveMove(from: lastStable, to: composite, oracle: oracle)
    }

    private static func majorityVote(_ frames: [BoardState]) -> BoardState {
        var result = BoardState()
        for file in 0..<8 {
            for rank in 0..<8 {
                var counts: [Occupant: Int] = [:]
                for frame in frames {
                    counts[frame[file, rank], default: 0] += 1
                }
                result[file, rank] = counts.max(by: { $0.value < $1.value })?.key ?? .empty
            }
        }
        return result
    }

    func reset(to state: BoardState = .startingPosition) {
        lastStable = state
        recentFrames.removeAll()
        lastEvaluatedComposite = nil
    }

    // MARK: - Move resolution

    private func resolveMove(from old: BoardState, to new: BoardState, oracle: MoveLegalityOracle) -> String? {
        let changed = BoardState.diffSquares(from: old, to: new)
        guard !changed.isEmpty else { return nil }

        switch changed.count {
        case 2:
            return resolveTwoSquareChange(changed, old: old, new: new, oracle: oracle)
        case 3:
            return resolveEnPassant(changed, old: old, new: new, oracle: oracle)
        case 4:
            return resolveCastling(changed, old: old, new: new, oracle: oracle)
        default:
            return nil
        }
    }

    private func resolveTwoSquareChange(
        _ changed: [(file: Int, rank: Int)],
        old: BoardState, new: BoardState,
        oracle: MoveLegalityOracle
    ) -> String? {
        let mover = oracle.sideToMove

        guard let origin = changed.first(where: {
            old[$0.file, $0.rank] == .piece(mover) && new[$0.file, $0.rank] == .empty
        }) else { return nil }

        guard let destination = changed.first(where: { $0.file != origin.file || $0.rank != origin.rank })
        else { return nil }

        guard new[destination.file, destination.rank] == .piece(mover),
              old[destination.file, destination.rank] != .piece(mover)
        else { return nil }

        return finalizeMove(
            originFile: origin.file, originRank: origin.rank,
            destFile: destination.file, destRank: destination.rank,
            oracle: oracle
        )
    }

    private func resolveEnPassant(
        _ changed: [(file: Int, rank: Int)],
        old: BoardState, new: BoardState,
        oracle: MoveLegalityOracle
    ) -> String? {
        let mover = oracle.sideToMove

        guard
            let origin = changed.first(where: { old[$0.file, $0.rank] == .piece(mover) && new[$0.file, $0.rank] == .empty }),
            let destination = changed.first(where: { old[$0.file, $0.rank] == .empty && new[$0.file, $0.rank] == .piece(mover) }),
            changed.contains(where: {
                $0.file == destination.file && $0.rank == origin.rank && new[$0.file, $0.rank] == .empty
            })
        else { return nil }

        return finalizeMove(
            originFile: origin.file, originRank: origin.rank,
            destFile: destination.file, destRank: destination.rank,
            oracle: oracle
        )
    }

    private func resolveCastling(
        _ changed: [(file: Int, rank: Int)],
        old: BoardState, new: BoardState,
        oracle: MoveLegalityOracle
    ) -> String? {
        let mover = oracle.sideToMove
        let vacated = changed.filter { old[$0.file, $0.rank] == .piece(mover) && new[$0.file, $0.rank] == .empty }
        let filled = changed.filter { old[$0.file, $0.rank] == .empty && new[$0.file, $0.rank] == .piece(mover) }
        guard vacated.count == 2, filled.count == 2 else { return nil }

        for kingOrigin in vacated {
            if let kingDest = filled.first(where: { $0.rank == kingOrigin.rank && abs($0.file - kingOrigin.file) == 2 }) {
                return finalizeMove(
                    originFile: kingOrigin.file, originRank: kingOrigin.rank,
                    destFile: kingDest.file, destRank: kingDest.rank,
                    oracle: oracle
                )
            }
        }
        return nil
    }

    private func finalizeMove(
        originFile: Int, originRank: Int,
        destFile: Int, destRank: Int,
        oracle: MoveLegalityOracle
    ) -> String? {
        let origin = Square(BoardState.squareName(file: originFile, rank: originRank))
        let destination = Square(BoardState.squareName(file: destFile, rank: destRank))

        guard oracle.legalDestinations(from: origin).contains(destination) else {
            return nil
        }

        var lan = origin.notation + destination.notation

        let isBackRank = (destRank == 7 && oracle.sideToMove == .white) || (destRank == 0 && oracle.sideToMove == .black)
        if isBackRank && oracle.isPawn(at: origin) {
            lan += "q"
        }
        return lan
    }
}
