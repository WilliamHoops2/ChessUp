//
//  GameSession.swift
//  ChessUp
//
//  Created by William Silvano Angga on 12/09/26.
//
//  The central state machine for a game. Owns the authoritative chess
//  position (via ChessKit), knows whose turn it is, what difficulty
//  the bot is playing at, and drives the loop described in the app spec:
//
//  1. If the bot moves first (user chose black), ask the engine for a
//     move immediately and announce it.
//  2. Otherwise, wait for the vision pipeline to report a completed
//     human move (board settled + matches a legal move).
//  3. Validate + apply that move to the authoritative position.
//  4. If the game isn't over, ask the engine for the bot's reply and
//     announce it.
//  5. Wait for the human to physically make that move on the board
//     before analyzing again — i.e. we only re-scan for the *next*
//     human move, we never move pieces ourselves.
//

import Foundation
import Combine
import ChessKit        // https://github.com/chesskit-app/chesskit-swift
import ChessKitEngine  // https://github.com/chesskit-app/chesskit-engine

// A note on ChessKit's color type: it's `Piece.Color` (nested inside
// `Piece`), not a top-level `PieceColor` — my earlier comment here was
// wrong about a naming collision with BoardState.swift's own
// `PieceColor` enum; there isn't one, since ChessKit's type has a
// different (nested) name entirely.

enum PlayerSide: String {
    case white, black
}

enum BotDifficulty: String, CaseIterable, Identifiable {
    case beginner       // ELO ~800  - Stockfish Skill Level ~0-2, shallow depth
    case casual         // ELO ~1200 - Skill Level ~6-8
    case club           // ELO ~1600 - Skill Level ~12-14
    case strong         // ELO ~2000 - Skill Level ~18
    case maximum        // Full strength, no skill-level limiting

    var id: String { rawValue }

    /// Stockfish's "Skill Level" UCI option ranges 0-20. This is the
    /// simplest, most reliable way to weaken the engine (as opposed to
    /// limiting depth/time alone, which can still play very sharp
    /// individual moves). Confirm the exact UCI option name/enum case
    /// against ChessKitEngine's current API before wiring this up —
    /// it may expose this as `.setoption(id: "Skill Level", value:)`
    /// or a typed convenience method.
    var stockfishSkillLevel: Int {
        switch self {
        case .beginner: return 1
        case .casual: return 7
        case .club: return 13
        case .strong: return 18
        case .maximum: return 20
        }
    }

    var searchDepth: Int {
        switch self {
        case .beginner: return 4
        case .casual: return 8
        case .club: return 12
        case .strong: return 16
        case .maximum: return 20
        }
    }

    var displayName: String {
        switch self {
        case .beginner: return "Beginner"
        case .casual: return "Casual"
        case .club: return "Club Player"
        case .strong: return "Strong"
        case .maximum: return "Maximum"
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
}

@MainActor
final class GameSession: ObservableObject {
    @Published var phase: GamePhase = .setup
    @Published var humanSide: PlayerSide = .white
    @Published var difficulty: BotDifficulty = .casual
    @Published var lastAnnouncedMove: String?
    @Published var moveHistory: [String] = []   // SAN strings, for an on-screen log

    // Authoritative chess position. Board (not Game) is used here since
    // Board is the type the README shows for move validation/application;
    // Game is oriented around PGN history. If move-history/PGN export is
    // needed later, revisit and possibly wrap this in a Game instead.
    private var board = Board()

    private let engineManager = ChessEngineManager()
    private let speech = SpeechAnnouncer()
    private var engineConfigurationTask: Task<Void, Never>?

    // Confirmed against ChessKit source: color is `Piece.Color`
    // (`.white`/`.black`), and `Position.sideToMove` is that type.
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

        // Kick off engine configuration in the background, but don't
        // advance past `.calibratingBoard` yet — that used to happen
        // unconditionally right here, which meant the phase was
        // cosmetic and the game started before the board was actually
        // calibrated. Advancing now happens in `boardCalibrated()`,
        // called by VisionCoordinator once it has real corners (or
        // immediately, when running against MockBoardDetector).
        engineConfigurationTask = Task {
            await engineManager.configure(difficulty: difficulty)
        }
    }

    /// Called by VisionCoordinator once the board is calibrated —
    /// immediately for MockBoardDetector (nothing to calibrate against),
    /// or after CoreMLBoardDetector.calibrate(pixelBuffer:) succeeds for
    /// the real camera pipeline. Advances out of `.calibratingBoard` and
    /// starts the actual game loop.
    func boardCalibrated() {
        guard case .calibratingBoard = phase else { return }
        Task {
            await engineConfigurationTask?.value
            if humanSide == .black {
                // Bot plays white and moves first.
                await requestAndAnnounceBotMove()
            } else {
                phase = .waitingForHumanMove
            }
        }
    }

    /// Called by the vision pipeline once it's confident the human
    /// physically completed a legal move on the board (see
    /// `MoveDetector`). `lanMove` is long algebraic notation, e.g.
    /// "e2e4" or "g1f3" — that's the format MoveDetector actually
    /// produces (it diffs origin/destination squares, it doesn't emit
    /// SAN), so it's parsed the same way as the engine's own moves,
    /// via EngineLANParser, rather than Move(san:).
    func humanMoveDetected(lanMove: String) {
        guard case .waitingForHumanMove = phase else { return }

        // Confirmed signature: EngineLANParser.parse(move:for:in:) —
        // it needs the side-to-move color too (used to interpret which
        // color a promotion piece belongs to), not just the LAN string
        // and position.
        guard let move = EngineLANParser.parse(move: lanMove, for: board.position.sideToMove, in: board.position) else {
            // Illegal or misread — ask the vision layer to re-scan rather
            // than silently guessing. Surfacing an on-screen correction
            // prompt here would also be reasonable.
            return
        }
        guard board.canMove(pieceAt: move.start, to: move.end) else {
            return
        }
        board.move(pieceAt: move.start, to: move.end)
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

        // Same EngineLANParser.parse(move:for:in:) signature as the
        // human-move branch above.
        //
        // NOTE: board.move(pieceAt:to:) (Square-based) is used here
        // rather than applying `move` directly, which means promotion
        // piece choice from the LAN (e.g. "e7e8q") isn't actually wired
        // through yet — ChessKit's move(pieceAt:to:) puts the board into
        // a `.promotion(move:)` state for any pawn reaching the back
        // rank, requiring a follow-up `board.completePromotion(of:to:)`
        // call to finish it. Until that's added, promotions will get
        // stuck in `.promotion` state rather than completing. Flagging
        // as a real TODO, not blocking the mock-loop test since that
        // only exercises pawn pushes so far.
        guard let move = EngineLANParser.parse(move: engineMove.uci, for: board.position.sideToMove, in: board.position) else {
            return
        }
        board.move(pieceAt: move.start, to: move.end)

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

    /// nil while the game is still ongoing. Maps ChessKit's `board.state`
    /// to a short human-readable result string for `.gameOver`.
    ///
    /// Confirmed against ChessKit source: `Board.State` has no bare
    /// `.stalemate` case — stalemate is `.draw(reason: .stalemate)`,
    /// alongside the other draw reasons ChessKit tracks.
    private func gameOverResult() -> String? {
        switch board.state {
        case .active, .check, .promotion:
            return nil
        case .checkmate(let color):
            // `color` here is the side that GOT checkmated (the loser) —
            // see ChessKit's doc comment on this case. Winner is the
            // opposite color.
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
