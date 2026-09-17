//
//  ColorSelectionView.swift
//  ChessUp
//
//  Created by William Silvano Angga on 17/09/26.
//

import SwiftUI

struct ColorSelectionView: View {
    @Binding var selectedSide: PlayerSide
    let onBack: () -> Void
    let onContinue: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                backButton
                    .padding(.bottom, 20)

                Text("WHICH SIDE DO YOU WANT TO PLAY AS ?")
                    .font(.system(size: 52, weight: .black, design: .default).width(.condensed))
                    .foregroundStyle(.white)
                    .lineSpacing(-6)
                    .fixedSize(horizontal: false, vertical: true)

                Text("You'll play these pieces on the physical board — the bot takes the other color.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.top, 14)
                    .frame(maxWidth: 290, alignment: .leading)

                Spacer(minLength: 36)

                HStack(spacing: 14) {
                    sideCard(.white)
                    sideCard(.black)
                }

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .safeAreaInset(edge: .bottom) {
                continueBar
            }
        }
    }
    
    private var backButton: some View {
        Button(action: onBack) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .bold))
                
                Text("BACK")
                    .font(
                        .system(
                            size: 13,
                            weight: .bold,
                            design: .default
                        )
                        .width(.condensed)
                    )
                    .tracking(1.5)
            }
            .foregroundStyle(.white.opacity(0.7))
        }
        .buttonStyle(.plain)
    }

    private func sideCard(_ side: PlayerSide) -> some View {
        let isSelected = selectedSide == side
        let isWhiteCard = side == .white

        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                selectedSide = side
            }
        } label: {
            VStack(spacing: 14) {
                Text(isWhiteCard ? "♙" : "♟")
                    .font(.system(size: 60))
                    .foregroundStyle(isWhiteCard ? .black : .white)

                Text(side == .white ? "WHITE" : "BLACK")
                    .font(.system(size: 14, weight: .bold, design: .default).width(.condensed))
                    .tracking(2)
                    .foregroundStyle(isWhiteCard ? .black : .white)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 168)
            .background(isWhiteCard ? Color.white : Color(white: 0.14))
            .overlay(
                Rectangle()
                    .strokeBorder(Color.white, lineWidth: isSelected ? 3 : 0)
            )
            .scaleEffect(isSelected ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
    }

    private var continueBar: some View {
        Button(action: onContinue) {
            HStack {
                Text("CONTINUE")
                    .font(.system(size: 14, weight: .bold, design: .default).width(.condensed))
                    .tracking(2)
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(Color.white)
        }
        .buttonStyle(.plain)
        .padding()
    }
}

#Preview {
    ColorSelectionView(
        selectedSide: .constant(.white),
        onBack: {},
        onContinue: {}
    )
}
