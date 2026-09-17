//
//  DifficultySelectionView.swift
//  ChessUp
//
//  Created by William Silvano Angga on 17/09/26.
//


import SwiftUI

struct DifficultySelectionView: View {
    @Binding var selectedDifficulty: BotDifficulty
    let onBack: () -> Void
    let onContinue: () -> Void

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                backButton

                Spacer()
                
                Text("CHOOSE YOUR\nOPPONENT")
                    .font(.system(size: 40, weight: .black, design: .default).width(.condensed))
                    .foregroundStyle(.black)
                    .lineSpacing(-4)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Select how challenging you want the bot to be.")
                    .font(.subheadline)
                    .foregroundStyle(.black.opacity(0.55))
                    .padding(.top, 12)

                Spacer()

                VStack(spacing: 10) {
                    difficultyRow(.easy)
                    difficultyRow(.medium)
                    difficultyRow(.hard)
                }

                Spacer()
            }
            .padding()
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 14) {
                    continueBar
                }
                .padding(.bottom, 6)
            }
        }
    }

    private var backButton: some View {
        Button(action: onBack) {
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.black)
                .frame(width: 32, height: 32)
        }
        .padding(.top, 4)
    }

    private func difficultyRow(_ level: BotDifficulty) -> some View {
        let isSelected = selectedDifficulty == level

        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                selectedDifficulty = level
            }
        } label: {
            HStack(spacing: 16) {
                Text(level.glyph)
                    .font(.system(size: 32))
                    .frame(width: 40)
                    .foregroundStyle(isSelected ? .white : .black)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(level.displayName.uppercased())
                            .font(.system(size: 15, weight: .bold, design: .default).width(.condensed))
                            .tracking(1)
                        difficultyDots(level, isSelected: isSelected)
                    }
                    Text(level.tagline)
                        .font(.system(size: 13))
                        .opacity(0.65)
                }
                .foregroundStyle(isSelected ? .white : .black)

                Spacer()

                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : .black)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .background(isSelected ? Color.black : Color.white)
            .overlay(
                Rectangle()
                    .strokeBorder(Color.black.opacity(isSelected ? 0 : 0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func difficultyDots(_ level: BotDifficulty, isSelected: Bool) -> some View {
        let filled: Int
        switch level {
        case .easy: filled = 1
        case .medium: filled = 2
        case .hard: filled = 3
        }
        let dotColor = isSelected ? Color.white : Color.black
        return HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(i < filled ? dotColor : dotColor.opacity(0.25))
                    .frame(width: 5, height: 5)
            }
        }
    }

    private var continueBar: some View {
        Button(action: onContinue) {
            HStack {
                Text("START GAME")
                    .font(.system(size: 14, weight: .bold, design: .default).width(.condensed))
                    .tracking(2)
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(Color.black)
        }
        .buttonStyle(.plain)
        .padding()
    }
}

#Preview {
    DifficultySelectionView(selectedDifficulty: .constant(.medium), onBack: {}, onContinue: {})
}
