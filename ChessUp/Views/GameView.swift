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

    @MainActor
    init(session: GameSession) {
        self.session = session
        let detector: BoardDetector = (try? CoreMLBoardDetector()) ?? MockBoardDetector()
        _vision = StateObject(wrappedValue: VisionCoordinator(session: session, detector: detector))
    }

    var body: some View {
        GeometryReader { outerGeo in
            let safeTop = outerGeo.safeAreaInsets.top
            let safeBottom = outerGeo.safeAreaInsets.bottom

            ZStack(alignment: .bottom) {
                if vision.isUsingMockDetector {
                    Color.black.ignoresSafeArea()
                } else {
                    CameraPreviewView(cameraManager: vision.cameraManager)
                        .ignoresSafeArea()
                    DebugOverlayView(
                        corners: vision.debugCorners,
                        cornerConfidences: vision.debugCornerConfidences,
                        imageSize: vision.debugImageSize,
                        statusMessage: vision.debugMessage,
                        isCalibrated: !session.phase.isCalibratingBoard,
                        warpedImage: vision.debugWarpedImage,
                        detectedPieces: vision.debugPieces,
                        boardGrid: vision.debugBoardGrid,
                        safeAreaTop: safeTop,
                        safeAreaBottom: safeBottom
                    )
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

                    if session.phase.isCalibratingBoard && vision.isReadyToConfirmSetup {
                        confirmSetupButton
                    }
                }
                .padding()
                .background(.black.opacity(0.5))
            }
            .overlay(alignment: .topLeading) { backButton }
        }
        .onAppear { vision.start() }
        .onDisappear { vision.stop() }
    }

    private var backButton: some View {
        Button {
            session.returnToSetup()
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.5))
                .clipShape(Circle())
        }
        .padding(.leading, 16)
        .padding(.top, 8)
    }

    #if DEBUG
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

    private var confirmSetupButton: some View {
        Button {
            vision.confirmBoardSetup()
        } label: {
            Text("Board is set up — Confirm")
                .font(.subheadline.bold())
                .foregroundStyle(.black)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.white)
                .clipShape(Capsule())
        }
    }

    private var statusBanner: some View {
        Group {
            switch session.phase {
            case .setup:
                Text("Setting up…")
            case .calibratingBoard:
                Text(vision.isReadyToConfirmSetup
                    ? "Board found — set up your pieces, then tap Confirm"
                    : "Point the camera at the board")
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
