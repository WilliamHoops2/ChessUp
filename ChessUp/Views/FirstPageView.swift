//
//  FirstPageView.swift
//  ChessUp
//
//  Created by William Silvano Angga on 17/09/26.
//

import SwiftUI

struct FirstPageView: View {
    
    let onContinue: () -> Void
    
    @State private var contentAppeared = false
    @State private var floatOffset: CGFloat = 0
    @State private var arrowOffset: CGFloat = 0
    
    var body: some View {
        ZStack {
            
            // MARK: - Main Content
            
            VStack {
                
                // Brand
                brandMark
                    .opacity(contentAppeared ? 1 : 0)
                    .offset(y: contentAppeared ? 0 : 20)
                
                Spacer()
                
                // Central Hero Graphic
                heroGraphic
                    .opacity(contentAppeared ? 1 : 0)
                    .scaleEffect(contentAppeared ? 1 : 0.8)
                
                Spacer()
                
                // Main Text
                VStack(alignment: .leading, spacing: 12) {
                    
                    Text("LEVEL UP YOUR GAME.")
                        .font(
                            .system(
                                size: 32,
                                weight: .black,
                                design: .default
                            )
                        )
                        .fontWidth(.condensed)
                        .foregroundStyle(.white)
                        .shadow(
                            color: .white.opacity(0.15),
                            radius: 8,
                            x: 0,
                            y: 0
                        )
                    
                    Text("PRACTICE AGAINST BOTS.")
                        .font(
                            .system(
                                size: 32,
                                weight: .black,
                                design: .default
                            )
                        )
                        .fontWidth(.condensed)
                        .foregroundStyle(.white)
                        .shadow(
                            color: .white.opacity(0.15),
                            radius: 8,
                            x: 0,
                            y: 0
                        )
                    
                    Text("ON A REAL CHESSBOARD.")
                        .font(
                            .system(
                                size: 32,
                                weight: .black,
                                design: .default
                            )
                        )
                        .fontWidth(.condensed)
                        .foregroundStyle(.white)
                        .shadow(
                            color: .white.opacity(0.15),
                            radius: 8,
                            x: 0,
                            y: 0
                        )
                    
                    Text("Practice. Adapt. Improve.")
                        .font(
                            .system(
                                size: 16,
                                weight: .medium
                            )
                        )
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.top, 8)
                }
                .opacity(contentAppeared ? 1 : 0)
                .offset(x: contentAppeared ? 0 : -20)
                
                Spacer()
                
                // Continue Button
                continueBar
                    .opacity(contentAppeared ? 1 : 0)
                    .offset(y: contentAppeared ? 0 : 30)
            }
            .padding(.horizontal)
        }
        
        // MARK: - Background
        
        .background {
            ZStack {
                
                // Dark gradient
                LinearGradient(
                    colors: [
                        .black,
                        Color(white: 0.08)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                
                // Subtle checkerboard texture
                Image(systemName: "checkerboard.rectangle")
                    .resizable()
                    .scaledToFill()
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
                    .foregroundStyle(.white)
                    .opacity(0.02)
                    .allowsHitTesting(false)
                    .clipped()
            }
            .ignoresSafeArea()
        }
        
        // MARK: - Animations
        
        .onAppear {
            
            // Main content fade in
            withAnimation(
                .easeOut(duration: 0.8)
                .delay(0.1)
            ) {
                contentAppeared = true
            }
            
            // Button arrow bounce
            withAnimation(
                .easeInOut(duration: 0.8)
                .repeatForever(autoreverses: true)
            ) {
                arrowOffset = 4
            }
            
            // Hero graphic floating animation
            withAnimation(
                .easeInOut(duration: 2.5)
                .repeatForever(autoreverses: true)
            ) {
                floatOffset = -12
            }
        }
    }
    
    // MARK: - Subviews
    
    private var heroGraphic: some View {
        ZStack {
            
            // Background ambient glow
            Circle()
                .fill(Color.white.opacity(0.05))
                .frame(width: 180, height: 180)
                .blur(radius: 20)
            
            // Core symbol representing progress/learning
            Image(systemName: "chevron.up.right.dotted.2")
                .font(
                    .system(
                        size: 180,
                        weight: .light
                    )
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            .white,
                            .white.opacity(0.3)
                        ],
                        startPoint: .bottomLeading,
                        endPoint: .topTrailing
                    )
                )
        }
        .offset(y: floatOffset)
    }
    
    private var brandMark: some View {
        HStack(
            alignment: .center,
            spacing: 8
        ) {
            
            Text("♛")
                .font(.system(size: 72))
                .foregroundStyle(.white)
                .padding(.bottom)
            
            Text("CHESSUP")
                .font(
                    .system(
                        size: 56,
                        weight: .bold,
                        design: .default
                    )
                )
                .fontWidth(.condensed)
                .tracking(2)
                .foregroundStyle(.white)
        }
    }
    
    private var continueBar: some View {
        Button(action: onContinue) {
            HStack {
                
                Text("START YOUR JOURNEY")
                    .font(
                        .system(
                            size: 14,
                            weight: .bold,
                            design: .default
                        )
                    )
                    .fontWidth(.condensed)
                    .tracking(1.5)
                
                Spacer()
                
                Image(systemName: "arrow.right")
                    .font(
                        .system(
                            size: 16,
                            weight: .semibold
                        )
                    )
                    .offset(x: arrowOffset)
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(Color.white)
        }
        .buttonStyle(.plain)
        .padding()
    }
}

// MARK: - Preview

#Preview {
    FirstPageView {}
}
