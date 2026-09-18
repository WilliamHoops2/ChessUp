//
//  ChessEngineManager.swift
//  ChessUp
//
//  Created by William Silvano Angga on 12/09/26.

import Foundation
import ChessKitEngine

struct EngineMove {
    let uci: String
}

actor ChessEngineManager {
    private var engine: Engine?

    func configure(difficulty: BotDifficulty) async {
        let engine = Engine(type: .stockfish)
        self.engine = engine
        await engine.start()

        await engine.send(command: .setoption(id: "Skill Level", value: "\(difficulty.stockfishSkillLevel)"))

        if let evalFile = Bundle.main.url(forResource: "nn-1111cefa1111", withExtension: "nnue"),
           let evalFileSmall = Bundle.main.url(forResource: "nn-37f18f62d772", withExtension: "nnue") {
            await engine.send(command: .setoption(id: "EvalFile", value: evalFile.path))
            await engine.send(command: .setoption(id: "EvalFileSmall", value: evalFileSmall.path))
        } else {
            print("⚠️ NNUE eval files not bundled yet — Stockfish will use its weaker built-in eval. See ARCHITECTURE.md / chesskit-engine README's \"Neural Networks\" section.")
        }
    }

    func bestMove(fen: String, difficulty: BotDifficulty) async -> EngineMove? {
        guard let engine, await engine.isRunning else { return nil }
        guard let responseStream = await engine.responseStream else { return nil }

        await engine.send(command: .stop)
        await engine.send(command: .position(.fen(fen)))
        await engine.send(command: .go(depth: difficulty.searchDepth))

        for await response in responseStream {
            if case let .bestmove(move, _) = response {
                return EngineMove(uci: move)
            }
        }
        return nil
    }
}
