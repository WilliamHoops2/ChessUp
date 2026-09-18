//
//  SetupView.swift
//  ChessUp
//
//  Created by William Silvano Angga on 17/09/26.
//

import SwiftUI

struct SetupView: View {
    @ObservedObject var session: GameSession

    @State private var step: Step = .intro
    @State private var selectedSide: PlayerSide = .white
    @State private var selectedDifficulty: BotDifficulty = .medium

    private enum Step {
        case intro
        case color
        case difficulty
    }

    var body: some View {
        Group {
            switch step {
            case .intro:
                FirstPageView {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        step = .color
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .leading),
                    removal: .move(edge: .leading)
                ))
            case .color:
                ColorSelectionView(
                    selectedSide: $selectedSide,
                    onBack: {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            step = .intro
                        }
                    },
                    onContinue: {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            step = .difficulty
                        }
                    }
                )
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
