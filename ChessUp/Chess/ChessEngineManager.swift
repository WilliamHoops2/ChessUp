//
//  ChessEngineManager.swift
//  ChessUp
//
//  Created by William Silvano Angga on 12/09/26.

import Foundation
import ChessKitEngine

/// `uci` is what the engine actually gives us (long algebraic, e.g.
/// "e2e4", "e7e8q" for promotion). SAN needs board context to
/// disambiguate and add check/mate suffixes, so it's produced by
/// GameSession via ChessKit's `Move`/`EngineLANParser` after the move
/// is applied to the authoritative Board, not here.
struct EngineMove {
    let uci: String
}

actor ChessEngineManager {
    private var engine: Engine?

    func configure(difficulty: BotDifficulty) async {
        let engine = Engine(type: .stockfish)
        self.engine = engine
        await engine.start()

        // NOTE: engine.start() is itself async and (per the compiler)
        // apparently awaits the underlying process actually coming up,
        // so the manual "poll for isRunning" fallback mentioned here
        // previously shouldn't be needed — awaiting start() should be
        // enough before sending setoption commands below.
        await engine.send(command: .setoption(id: "Skill Level", value: "\(difficulty.stockfishSkillLevel)"))

        // REQUIRED — Stockfish 17 needs NNUE eval files or play quality
        // degrades to its (much weaker) built-in fallback eval. Download
        // nn-1111cefa1111.nnue and nn-37f18f62d772.nnue from
        // https://tests.stockfishchess.org and add them to the ChessUp
        // target's bundle resources (drag into Xcode, check "Copy items
        // if needed" + target membership) before relying on this.
        if let evalFile = Bundle.main.url(forResource: "nn-1111cefa1111", withExtension: "nnue"),
           let evalFileSmall = Bundle.main.url(forResource: "nn-37f18f62d772", withExtension: "nnue") {
            await engine.send(command: .setoption(id: "EvalFile", value: evalFile.path))
            await engine.send(command: .setoption(id: "EvalFileSmall", value: evalFileSmall.path))
        } else {
            print("⚠️ NNUE eval files not bundled yet — Stockfish will use its weaker built-in eval. See ARCHITECTURE.md / chesskit-engine README's \"Neural Networks\" section.")
        }
    }

    /// Returns nil if the engine isn't ready or the position is
    /// terminal (checkmate/stalemate) — callers should check game-over
    /// state via ChessKit before calling this rather than relying on
    /// nil to mean "game over".
    func bestMove(fen: String, difficulty: BotDifficulty) async -> EngineMove? {
        guard let engine, await engine.isRunning else { return nil }
        guard let responseStream = await engine.responseStream else { return nil }

        await engine.send(command: .stop)
        await engine.send(command: .position(.fen(fen)))
        await engine.send(command: .go(depth: difficulty.searchDepth))

        // NOTE: `.bestmove` takes two associated values (per the
        // compiler) — matches UCI's "bestmove <move> ponder <move>"
        // wire format: the move itself, plus an optional ponder move
        // the engine expects the opponent to play next. We only need
        // the first value; the ponder move isn't used since this app
        // doesn't implement pondering (thinking during the human's
        // turn) at all.
        for await response in responseStream {
            if case let .bestmove(move, _) = response {
                return EngineMove(uci: move)
            }
        }
        return nil
    }
}
