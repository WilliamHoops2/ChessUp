//
//  MoveDetector.swift
//  ChessUp
//
//  Created by William Silvano Angga on 12/09/26.
//
//  Bridges the "noisy" vision world (BoardState snapshots) to the
//  "authoritative" chess world (a legal move ChessKit can apply).
//
//  Core idea: don't try to classify a move type from pixels directly.
//  Instead, diff two consecutive *stable* BoardState snapshots (see
//  debouncing note below) and figure out which of ChessKit's legal
//  moves from the current position would produce that exact resulting
//  board. This piggybacks on ChessKit's rules engine so we never have
//  to hand-roll castling/en passant/promotion detection logic — if the
//  resulting squares match a legal move, it's that move.
//

import Foundation
// import ChessKit — not needed directly in this file yet; the TODO
// below covers upgrading resolveMove() to use ChessKit's Board.

final class MoveDetector {
    /// Require the board to look identical across this many consecutive
    /// frames before treating it as "settled" — this is what prevents
    /// the app from reacting mid-move, while a hand is still over the
    /// board, or to a single bad frame.
    private let requiredStableFrames = 3

    private var pendingState: BoardState?
    private var stableCount = 0
    private(set) var lastStableState: BoardState = .startingPosition

    /// Feed every vision-detected frame here. Returns a long-algebraic
    /// move string (e.g. "e2e4") — not SAN — only once a) the board has
    /// settled into a new stable state and b) that state corresponds to
    /// exactly one legal move from the last stable state.
    func ingest(_ observed: BoardState) -> String? {
        if observed == pendingState {
            stableCount += 1
        } else {
            pendingState = observed
            stableCount = 1
        }

        guard stableCount >= requiredStableFrames else { return nil }
        guard observed != lastStableState else { return nil } // nothing changed

        defer {
            lastStableState = observed
            pendingState = nil
            stableCount = 0
        }

        return resolveMove(from: lastStableState, to: observed)
    }

    /// TODO: replace this manual diff with ChessKit once it's added as
    /// a dependency — generate `board.legalMoves` from the current
    /// ChessKit position, apply each candidate to a scratch board, and
    /// return the long-algebraic form of whichever candidate's resulting
    /// square occupancy matches `to`. That approach is strictly better
    /// than the heuristic below because it guarantees the result is
    /// legal and correctly handles castling (2 squares change on each
    /// side), en passant (the captured pawn disappears from a 3rd
    /// square), and promotion (piece kind changes on arrival).
    private func resolveMove(from: BoardState, to: BoardState) -> String? {
        let changed = BoardState.diffSquares(from: from, to: to)

        // Simplest case: exactly one square lost its piece, one square
        // gained a piece of the same color/kind (or a captured piece
        // was replaced). Good enough as a placeholder; swap for the
        // ChessKit-based approach above before relying on this for
        // castling/en passant/promotion.
        guard changed.count == 2 else { return nil }

        let a = changed[0], b = changed[1]
        let aWasOccupied = from[a.file, a.rank] != nil
        let bWasOccupied = from[b.file, b.rank] != nil

        let (originFile, originRank, destFile, destRank): (Int, Int, Int, Int)
        if aWasOccupied && to[a.file, a.rank] == nil {
            (originFile, originRank, destFile, destRank) = (a.file, a.rank, b.file, b.rank)
        } else if bWasOccupied && to[b.file, b.rank] == nil {
            (originFile, originRank, destFile, destRank) = (b.file, b.rank, a.file, a.rank)
        } else {
            return nil
        }

        guard to[destFile, destRank] != nil else { return nil }
        let originSquare = BoardState.squareName(file: originFile, rank: originRank)
        let destSquare = BoardState.squareName(file: destFile, rank: destRank)

        // This is long algebraic notation (LAN) — "e2e4", not SAN. That's
        // intentional: GameSession.humanMoveDetected(lanMove:) parses this
        // via ChessKit's EngineLANParser, the same path used for the
        // engine's own moves. Still worth the ChessKit-based upgrade noted
        // above once it's wired in — this heuristic doesn't handle
        // castling (2 squares change per side), en passant (captured pawn
        // vanishes from a 3rd square), or promotion (piece kind changes
        // on arrival) correctly yet.
        return "\(originSquare)\(destSquare)"
    }
}
