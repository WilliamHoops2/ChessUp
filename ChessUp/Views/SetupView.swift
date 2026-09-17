//
//  SetupView.swift
//  ChessUp
//
//  Two-step setup flow: pick a side (ColorSelectionView), then pick
//  bot difficulty (DifficultySelectionView), then start the game. This
//  file just holds the shared selection state and steps between the
//  two screens — see those files for the actual visual design.
//

import SwiftUI

struct SetupView: View {
    @ObservedObject var session: GameSession

    @State private var step: Step = .color
    @State private var selectedSide: PlayerSide = .white
    @State private var selectedDifficulty: BotDifficulty = .medium

    private enum Step {
        case color
        case difficulty
    }

    var body: some View {
        Group {
            switch step {
            case .color:
                ColorSelectionView(selectedSide: $selectedSide) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        step = .difficulty
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .leading),
                    removal: .move(edge: .leading)
                ))
            case .difficulty:
                DifficultySelectionView(
                    selectedDifficulty: $selectedDifficulty,
                    onBack: {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            step = .color
                        }
                    },
                    onContinue: {
                        session.startGame(humanSide: selectedSide, difficulty: selectedDifficulty)
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing),
                    removal: .move(edge: .trailing)
                ))
            }
        }
    }
}

#Preview {
    SetupView(session: GameSession())
}
