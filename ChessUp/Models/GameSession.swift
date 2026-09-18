//
//  GameSession.swift
//  ChessUp
//
//  Created by William Silvano Angga on 12/09/26.
//

import Foundation
import Combine
import ChessKit        // https://github.com/chesskit-app/chesskit-swift
import ChessKitEngine  // https://github.com/chesskit-app/chesskit-engine

enum PlayerSide: String {
    case white, black
}

enum BotDifficulty: String, CaseIterable, Identifiable {
    case easy
    case medium
    case hard

    var id: String { rawValue }

    var stockfishSkillLevel: Int {
        switch self {
        case .easy: return 2
        case .medium: return 10
        case .hard: return 18
        }
    }

    var searchDepth: Int {
        switch self {
        case .easy: return 4
        case .medium: return 10
        case .hard: return 16
        }
    }

    var displayName: String {
        switch self {
        case .easy: return "Easy"
        case .medium: return "Medium"
        case .hard: return "Hard"
        }
    }

    var glyph: String {
        switch self {
        case .easy: return "♟"
        case .medium: return "♞"
        case .hard: return "♛"
        }
    }

    var tagline: String {
        switch self {
        case .easy: return "New to chess? Start here."
        case .medium: return "Know the basics? Step it up."
        case .hard: return "Ready for a real challenge?"
        }
    }
}

enum GamePhase {
    case setup
    case calibratingBoard
    case waitingForHumanMove
    case engineThinking
    case announcingBotMove
    case gameOver(result: String)

    var isWaitingForHumanMove: Bool {
        if case .waitingForHumanMove = self { return true }
        return false
    }

    var isCalibratingBoard: Bool {
        if case .calibratingBoard = self { return true }
        return false
    }
}

@MainActor
final class GameSession: ObservableObject {
    @Published var phase: GamePhase = .setup
    @Published var humanSide: PlayerSide = .white
    @Published var difficulty: BotDifficulty = .medium
    @Published var lastAnnouncedMove: String?
    @Published var moveHistory: [String] = []
    private var board = Board()

    private let engineManager = ChessEngineManager()
    private let speech = SpeechAnnouncer()
    private var engineConfigurationTask: Task<Void, Never>?

    var isBotTurn: Bool {
        let sideToMove = board.position.sideToMove
        let botSide: Piece.Color = humanSide == .white ? .black : .white
        return sideToMove == botSide
    }

    func startGame(humanSide: PlayerSide, difficulty: BotDifficulty) {
        self.humanSide = humanSide
        self.difficulty = difficulty
        self.board = Board()
        moveHistory = []
        phase = .calibratingBoard

        engineConfigurationTask = Task {
            await engineManager.configure(difficulty: difficulty)
        }
    }

    func boardCalibrated() {
        guard case .calibratingBoard = phase else { return }
        Task {
            await engineConfigurationTask?.value
            if humanSide == .black {
                await requestAndAnnounceBotMove()
            } else {
                phase = .waitingForHumanMove
            }
        }
    }

    func returnToSetup() {
        engineConfigurationTask?.cancel()
        engineConfigurationTask = nil
        board = Board()
        moveHistory = []
        lastAnnouncedMove = nil
        phase = .setup
    }

    func humanMoveDetected(lanMove: String) {
        guard case .waitingForHumanMove = phase else { return }

        guard let move = EngineLANParser.parse(move: lanMove, for: board.position.sideToMove, in: board.position) else {
            return
        }
        guard board.canMove(pieceAt: move.start, to: move.end) else {
            return
        }
        applyMove(move)
        moveHistory.append(move.san)

        if let result = gameOverResult() {
            phase = .gameOver(result: result)
            return
        }

        Task {
            await requestAndAnnounceBotMove()
        }
    }

    private func requestAndAnnounceBotMove() async {
        phase = .engineThinking
        guard let engineMove = await engineManager.bestMove(fen: board.position.fen, difficulty: difficulty) else {
            return
        }

        guard let move = EngineLANParser.parse(move: engineMove.uci, for: board.position.sideToMove, in: board.position) else {
            return
        }
        applyMove(move)

        moveHistory.append(move.san)
        lastAnnouncedMove = move.san
        phase = .announcingBotMove
        speech.announce(sanMove: move.san)

        if let result = gameOverResult() {
            phase = .gameOver(result: result)
        } else {
            phase = .waitingForHumanMove
        }
    }

    private func applyMove(_ move: Move) {
        board.move(pieceAt: move.start, to: move.end)
        if case .promotion(let pendingMove) = board.state {
            board.completePromotion(of: pendingMove, to: .queen)
        }
    }

    private func gameOverResult() -> String? {
        switch board.state {
        case .active, .check, .promotion:
            return nil
        case .checkmate(let color):
            let winner = color.opposite == .white ? "White" : "Black"
            return "Checkmate — \(winner) wins"
        case .draw(let reason):
            switch reason {
            case .stalemate: return "Stalemate — draw"
            case .fiftyMoves: return "Draw — fifty-move rule"
            case .insufficientMaterial: return "Draw — insufficient material"
            case .repetition: return "Draw — threefold repetition"
            case .agreement: return "Draw by agreement"
            }
        }
    }
}

// MARK: - MoveLegalityOracle

extension GameSession: MoveLegalityOracle {
    var sideToMove: Piece.Color {
        board.position.sideToMove
    }

    func legalDestinations(from square: Square) -> [Square] {
        board.legalMoves(forPieceAt: square)
    }

    func isPawn(at square: Square) -> Bool {
        board.position.piece(at: square)?.kind == .pawn
    }
}
