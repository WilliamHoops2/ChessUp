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
    
    @State private var displayedSide: PlayerSide = .white
    @State private var iconScale: CGFloat = 1.0
    @State private var iconOpacity: Double = 1.0

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
                .ignoresSafeArea()
            
            VStack(spacing: 32) {
                Image(displayedSide == .white ? "ChessIconWht" : "ChessIconBlk")
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(iconScale)
                    .opacity(iconOpacity)
                    .onChange(of: selectedSide) {
                        withAnimation(.easeIn(duration: 0.15)) {
                            iconScale = 0.85
                            iconOpacity = 0
                        }

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            displayedSide = selectedSide

                            withAnimation(.easeOut(duration: 0.15)) {
                                iconScale = 1.0
                                iconOpacity = 1.0
                            }
                        }
                    }
                
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
}

#Preview {
    SetupView(session: GameSession())
}
