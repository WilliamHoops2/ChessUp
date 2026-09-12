//
//  GameView.swift
//  ChessUp
//
//  Created by William Silvano Angga on 12/09/26.
//

import SwiftUI

struct GameView: View {
    @ObservedObject var session: GameSession
    @StateObject private var vision: VisionCoordinator

    #if DEBUG
    @State private var simulateFrom = "e2"
    @State private var simulateTo = "e4"
    #endif

    // Marked @MainActor explicitly: VisionCoordinator's own init is
    // main-actor-isolated (the whole class is @MainActor), but a
    // View's custom init isn't automatically main-actor-isolated under
    // strict concurrency checking, even though body/SwiftUI's runtime
    // lifecycle always runs on the main actor in practice. Without this,
    // the compiler flags calling VisionCoordinator's init here as "main
    // actor-isolated initializer called from a synchronous nonisolated
    // context."
    @MainActor
    init(session: GameSession) {
        self.session = session
        // Real detector when the converted .mlpackage models are in the
        // bundle; falls back to MockBoardDetector otherwise (e.g. a
        // Simulator run before they've been dragged into Xcode) so the
        // rest of the app keeps working either way.
        //
        // KNOWN ISSUE: CoreMLBoardDetector's init loads three Core ML
        // models (~180MB combined) synchronously, and this runs on the
        // main thread during the SetupView -> GameView transition —
        // expect a visible hitch here. Loading them off the main actor
        // and swapping VisionCoordinator's detector in once ready (it's
        // currently a `let`, so that also needs to become a `var`) is
        // the real fix; deferring that refactor for now since it
        // touches VisionCoordinator's threading contract.
        let detector: BoardDetector = (try? CoreMLBoardDetector()) ?? MockBoardDetector()
        _vision = StateObject(wrappedValue: VisionCoordinator(session: session, detector: detector))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Live camera feed for whoever's holding the phone to line
            // up the board — purely visual, has no effect on detection
            // (VisionCoordinator reads frames independently). Falls back
            // to plain black when running against MockBoardDetector,
            // since CameraManager's session was never started in that
            // case (see VisionCoordinator.start()) and there'd be
            // nothing to preview. A BoardCalibrationView overlay during
            // `.calibratingBoard` (drag the 4 corners to align them) is
            // still a good future addition — CoreMLBoardDetector
            // auto-calibrates from the first frame it finds the board
            // in, so this works without the overlay too.
            if vision.isUsingMockDetector {
                Color.black.ignoresSafeArea()
            } else {
                CameraPreviewView(cameraManager: vision.cameraManager)
                    .ignoresSafeArea()
            }

            VStack(spacing: 16) {
                statusBanner

                if let last = session.lastAnnouncedMove {
                    Text(last)
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                }

                ScrollView(.horizontal) {
                    HStack {
                        ForEach(Array(session.moveHistory.enumerated()), id: \.offset) { _, move in
                            Text(move)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.white.opacity(0.15))
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                        }
                    }
                }

                #if DEBUG
                if vision.isUsingMockDetector {
                    debugMoveSimulator
                }
                #endif
            }
            .padding()
            .background(.black.opacity(0.5))
        }
        .onAppear { vision.start() }
        .onDisappear { vision.stop() }
    }

    #if DEBUG
    /// Lets you exercise the full loop (MoveDetector -> GameSession ->
    /// Stockfish -> SpeechAnnouncer) without a camera or trained vision
    /// model — this is the "validate end-to-end with MockBoardDetector"
    /// step from ARCHITECTURE.md. Only appears when VisionCoordinator is
    /// actually using MockBoardDetector, and is compiled out of
    /// non-debug builds entirely.
    private var debugMoveSimulator: some View {
        VStack(spacing: 8) {
            Text("Debug: simulate a move")
                .font(.caption.bold())
                .foregroundStyle(.white.opacity(0.6))
            HStack(spacing: 8) {
                TextField("from", text: $simulateFrom)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.white.opacity(0.6))
                TextField("to", text: $simulateTo)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                Button("Simulate") {
                    vision.simulateHumanMove(from: simulateFrom, to: simulateTo)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!session.phase.isWaitingForHumanMove)
            }
        }
        .padding(.top, 8)
    }
    #endif

    private var statusBanner: some View {
        Group {
            switch session.phase {
            case .setup:
                Text("Setting up…")
            case .calibratingBoard:
                Text("Point the camera at the board")
            case .waitingForHumanMove:
                Text("Your move — make it on the board")
            case .engineThinking:
                Text("Thinking…")
            case .announcingBotMove:
                Text("Bot's move")
            case .gameOver(let result):
                Text(result)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.white.opacity(0.8))
    }
}

#Preview {
    GameView(session: GameSession())
}
