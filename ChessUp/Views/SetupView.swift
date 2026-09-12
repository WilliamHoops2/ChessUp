//
//  SetupView.swift
//  ChessUp
//
//  Created by William Silvano Angga on 12/09/26.
//

import SwiftUI

struct SetupView: View {
    @ObservedObject var session: GameSession
    @State private var selectedSide: PlayerSide = .white
    @State private var selectedDifficulty: BotDifficulty = .casual

    var body: some View {
        VStack(spacing: 32) {
            Text("ChessUp")
                .font(.largeTitle.bold())

            VStack(alignment: .leading, spacing: 12) {
                Text("Play as")
                    .font(.headline)
                Picker("Side", selection: $selectedSide) {
                    Text("White").tag(PlayerSide.white)
                    Text("Black").tag(PlayerSide.black)
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Bot difficulty")
                    .font(.headline)
                Picker("Difficulty", selection: $selectedDifficulty) {
                    ForEach(BotDifficulty.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.wheel)
            }

            Button {
                session.startGame(humanSide: selectedSide, difficulty: selectedDifficulty)
            } label: {
                Text("Set Up Board")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(24)
    }
}

#Preview {
    SetupView(session: GameSession())
}
