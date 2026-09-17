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
    case easy    // ELO ~800  - Stockfish Skill Level ~2, shallow depth
    case medium  // ELO ~1400 - Skill Level ~10
    case hard    // ELO ~2000+ - Skill Level ~18

    var id: String { rawValue }

    /// Stockfish's "Skill Level" UCI option ranges 0-20. This is the
    /// simplest, most reliable way to weaken the engine (as opposed to
    /// limiting depth/time alone, which can still play very sharp
    /// individual moves).
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

    /// Unicode chess glyph representing this difficulty on the setup
    /// screen — pawn = easy, knight = medium, queen = hard, per the
    /// design brief. Reads intuitively even to someone who doesn't
    /// know chess piece values: a bigger/fancier-looking piece just
    /// feels harder.
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

    /// Abandons the current game and returns to the setup screen —
    /// called from GameView's back button. Cancels any in-flight engine
    /// configuration and resets the board/history so a fresh
    /// `startGame` afterward doesn't inherit stale state. Doesn't touch
    /// the camera/vision pipeline itself — GameView's `.onDisappear`
    /// (triggered once ContentView switches back to SetupView as
    /// `phase` changes) already calls `VisionCoordinator.stop()`.
    func returnToSetup() {
        engineConfigurationTask?.cancel()
        engineConfigurationTask = nil
        board = Board()
        moveHistory = []
        lastAnnouncedMove = nil
        phase = .setup
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

        // Same EngineLANParser.parse(move:for:in:) signature as the
        // human-move branch above.
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

    /// Applies a validated move to the board, completing any pawn
    /// promotion by auto-queening. Promotion piece choice isn't
    /// detectable by the simplified color-only vision pipeline (a
    /// promoted pawn looks the same regardless of what it became), and
    /// MoveDetector's own LAN output already assumes queen for the same
    /// reason, so this keeps both move-application paths consistent
    /// with that choice. `board.move(pieceAt:to:)` alone leaves the
    /// board sitting in a `.promotion(move:)` state for any pawn
    /// reaching the back rank rather than completing the move, which is
    /// what `completePromotion` finishes here.
    private func applyMove(_ move: Move) {
        board.move(pieceAt: move.start, to: move.end)
        if case .promotion(let pendingMove) = board.state {
            board.completePromotion(of: pendingMove, to: .queen)
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

// MARK: - MoveLegalityOracle

/// Lets MoveDetector (owned by VisionCoordinator, not GameSession)
/// query the current chess position's legality without VisionCoordinator
/// needing direct access to `board`, which stays private.
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
