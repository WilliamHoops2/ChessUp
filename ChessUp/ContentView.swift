//
//  ContentView.swift
//  ChessUp
//
//  Created by William Silvano Angga on 10/09/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var session = GameSession()

    var body: some View {
        Group {
            switch session.phase {
            case .setup:
                SetupView(session: session)
            default:
                GameView(session: session)
            }
        }
    }
}

#Preview {
    ContentView()
}
