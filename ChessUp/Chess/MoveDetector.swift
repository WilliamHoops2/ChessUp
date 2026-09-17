//
//  MoveDetector.swift
//  ChessUp
//
//  Created by William Silvano Angga on 15/09/26.
//
//  Detects physical piece moves by diffing successive occupancy
//  snapshots (see BoardState/Occupant) against each other.
//
//  Deliberately never attempts to identify WHAT piece is on a square
//  (pawn vs knight vs queen, etc) — only whether each square is empty,
//  occupied by white, or occupied by black. Piece KIND is tracked
//  entirely by GameSession/ChessKit, derived from the known starting
//  position plus every legal move played since. This class's only job
//  is: given which squares changed, which single legal move explains
//  that change?
//
//  Every move type produces a distinct, recognizable diff pattern:
//    Normal move:  2 squares change (origin: color→empty, destination: empty→color)
//    Capture:      2 squares change (origin: color→empty, destination: colorA→colorB directly, no empty state)
//    En passant:   3 squares change (origin, destination, AND the captured
//                  pawn's square — which is NOT the destination square)
//    Castling:     4 squares change (king pair + rook pair)
//  Anything else (0, 1, or 5+ squares changed) doesn't match any legal
//  chess move between two stable positions and is treated as a
//  misdetection — rejected rather than guessed at.
//

import Foundation
import ChessKit

/// Supplies the current chess position's legality info so MoveDetector
/// can disambiguate captures/castling/en passant and reject diffs that
/// don't correspond to any legal move. GameSession conforms to this
/// (see the extension in GameSession.swift); kept as a protocol rather
/// than passing GameSession directly so MoveDetector stays testable
/// and decoupled from the rest of the app.
protocol MoveLegalityOracle {
    var sideToMove: Piece.Color { get }
    func legalDestinations(from square: Square) -> [Square]
    func isPawn(at square: Square) -> Bool
}

final class MoveDetector {
    private var lastStable: BoardState = .startingPosition

    // Rolling window of the most recent raw (un-smoothed) frames.
    // "Stable" is now defined per-square, by majority vote across this
    // window, rather than requiring the whole 64-square snapshot to be
    // byte-identical across consecutive frames. That distinction
    // matters a lot in practice: OccupancyClassifier re-samples colors
    // from scratch every frame with no memory between frames, so it's
    // completely normal for one or two boundary-case squares to
    // flicker between two classifications frame-to-frame even when
    // nothing on the board actually changed. Requiring byte-identical
    // consecutive frames meant a SINGLE flickering square anywhere on
    // the board could reset the "stable" counter forever, which is
    // very likely why moves weren't registering at all — majority
    // voting absorbs that kind of isolated per-frame noise instead of
    // being derailed by it, while still needing the board to have
    // genuinely settled (not mid-motion) for the vote to converge on
    // anything.
    private var recentFrames: [BoardState] = []
    private let windowSize = 5
    /// The last majority-vote composite already evaluated against
    /// `lastStable` — guards against reprocessing (and re-resolving)
    /// the exact same composite on every subsequent frame once the
    /// window is full of identical votes, which would otherwise
    /// harmlessly but pointlessly redo the same legal-move lookup work
    /// every frame.
    private var lastEvaluatedComposite: BoardState?

    /// Feed every vision-detected frame here. Returns a long-algebraic
    /// move string (e.g. "e2e4", or "e7e8q" for a pawn reaching the
    /// back rank — see the auto-queen note in `finalizeMove`) only
    /// once a) the last `windowSize` frames' majority-vote composite
    /// differs from the last stable state (i.e. the board has actually
    /// settled into something new) and b) that state's diff from the
    /// last stable state matches exactly one legal move given `oracle`.
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

    /// Per-square majority vote across a window of recent frames — the
    /// occupant that appeared most often on that square wins. A tie
    /// (only possible with an even window, which `windowSize` avoids
    /// by being odd) falls back to whichever candidate happened to be
    /// enumerated first, which in practice means this never actually
    /// needs to break a tie.
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

    /// Explicitly resets tracking to a fresh board (e.g. starting a new
    /// game) without needing several stable frames to "unlearn" the
    /// previous game's final position.
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
            // 1 square changing means something was picked up and not
            // yet put down (shouldn't reach here given the stable-frame
            // debounce, but defensive anyway); 5+ means multiple
            // pieces were disturbed, a hand lingered over several
            // squares, or the board was bumped. None of these are a
            // single legal move — reject and let vision keep watching.
            return nil
        }
    }

    /// Handles both plain moves and direct captures — both change
    /// exactly 2 squares, just with a different transition shape:
    ///   Plain move:  color→empty (origin) + empty→color (destination)
    ///   Capture:     color→empty (origin) + colorA→colorB (destination)
    private func resolveTwoSquareChange(
        _ changed: [(file: Int, rank: Int)],
        old: BoardState, new: BoardState,
        oracle: MoveLegalityOracle
    ) -> String? {
        let mover = oracle.sideToMove

        // The origin is whichever changed square went from
        // "occupied by the side to move" to empty — that's true for
        // both a plain move and a capture.
        guard let origin = changed.first(where: {
            old[$0.file, $0.rank] == .piece(mover) && new[$0.file, $0.rank] == .empty
        }) else { return nil }

        guard let destination = changed.first(where: { $0.file != origin.file || $0.rank != origin.rank })
        else { return nil }

        // Destination must now hold the mover's color, having NOT
        // held it before (covers both empty→color and
        // opponentColor→moverColor — i.e. both plain moves and
        // captures land here).
        guard new[destination.file, destination.rank] == .piece(mover),
              old[destination.file, destination.rank] != .piece(mover)
        else { return nil }

        return finalizeMove(
            originFile: origin.file, originRank: origin.rank,
            destFile: destination.file, destRank: destination.rank,
            oracle: oracle
        )
    }

    /// En passant: 3 squares change — origin, destination, and the
    /// captured pawn's square (same file as destination, same rank as
    /// origin — critically NOT the destination square itself, which is
    /// what makes en passant look different from every other move).
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

    /// Castling: 4 squares change — king origin/destination and rook
    /// origin/destination, all the mover's color. The king always
    /// moves exactly 2 files in standard chess, which is what
    /// distinguishes it from the rook pair here.
    private func resolveCastling(
        _ changed: [(file: Int, rank: Int)],
        old: BoardState, new: BoardState,
        oracle: MoveLegalityOracle
    ) -> String? {
        let mover = oracle.sideToMove
        let vacated = changed.filter { old[$0.file, $0.rank] == .piece(mover) && new[$0.file, $0.rank] == .empty }
        let filled = changed.filter { old[$0.file, $0.rank] == .empty && new[$0.file, $0.rank] == .piece(mover) }
        guard vacated.count == 2, filled.count == 2 else { return nil }

        // Find the (origin, destination) pair among the two
        // vacated/filled squares whose file distance is exactly 2 —
        // that's the king. The rook's file distance varies (3 on a
        // standard board) and isn't needed to identify the move: once
        // we know the king's origin/destination, that alone is enough
        // for EngineLANParser/ChessKit to recognize it as a castling
        // move and move the rook itself.
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

    /// Common tail for every pattern above: convert to Square notation,
    /// cross-check against the oracle's legal moves — rejecting the
    /// diff outright if it doesn't correspond to a real legal move,
    /// which is the safety net against a vision misdetection silently
    /// corrupting the tracked game state — and auto-queen if a pawn
    /// lands on the back rank.
    private func finalizeMove(
        originFile: Int, originRank: Int,
        destFile: Int, destRank: Int,
        oracle: MoveLegalityOracle
    ) -> String? {
        // Using the String-notation initializer (Square("e4")) rather
        // than Square(File, Rank) — the two-argument initializer was
        // triggering a confusing overload-resolution error (Swift
        // matching it against Square's single-String-argument init
        // instead), and the notation string is exactly what
        // BoardState.squareName already produces for this purpose.
        let origin = Square(BoardState.squareName(file: originFile, rank: originRank))
        let destination = Square(BoardState.squareName(file: destFile, rank: destRank))

        guard oracle.legalDestinations(from: origin).contains(destination) else {
            return nil
        }

        var lan = origin.notation + destination.notation

        // Auto-queen: promotion piece choice isn't visually detectable
        // by a color-only vision pipeline (a promoted pawn looks the
        // same color-wise no matter what it became), so this always
        // assumes queen — the overwhelmingly common real-world choice,
        // and the same convention ChessEngineManager's own moves use.
        // Only append "q" when the piece actually moving IS a pawn —
        // otherwise this would wrongly tag e.g. a rook legitimately
        // landing on the back rank as a promotion.
        let isBackRank = (destRank == 7 && oracle.sideToMove == .white) || (destRank == 0 && oracle.sideToMove == .black)
        if isBackRank && oracle.isPawn(at: origin) {
            lan += "q"
        }
        return lan
    }
}
