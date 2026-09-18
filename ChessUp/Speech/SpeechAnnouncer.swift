//
//  SpeechAnnouncer.swift
//  ChessUp
//
//  Created by William Silvano Angga on 12/09/26.
//

import AVFoundation

final class SpeechAnnouncer: NSObject {
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[ChessUp Speech] ⚠️ failed to configure audio session: \(error) — announcements may not play if the phone is muted")
        }
    }

    func announce(sanMove: String) {
        let phrase = spokenPhrase(for: sanMove)
        let utterance = AVSpeechUtterance(string: phrase)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        synthesizer.speak(utterance)
    }

    private func spokenPhrase(for san: String) -> String {
        var text = san

        if text == "O-O" { return "Castles king side" }
        if text == "O-O-O" { return "Castles queen side" }

        var suffix = ""
        if text.hasSuffix("#") {
            suffix = ", checkmate"
            text.removeLast()
        } else if text.hasSuffix("+") {
            suffix = ", check"
            text.removeLast()
        }

        let pieceNames: [Character: String] = [
            "N": "Knight", "B": "Bishop", "R": "Rook", "Q": "Queen", "K": "King"
        ]

        var pieceWord = "Pawn"
        if let first = text.first, let name = pieceNames[first] {
            pieceWord = name
            text.removeFirst()
        }

        let isCapture = text.contains("x")
        text = text.replacingOccurrences(of: "x", with: "")

        var promotionWord = ""
        if let eqRange = text.range(of: "=") {
            let promoChar = text[text.index(after: eqRange.lowerBound)...]
            if let piece = promoChar.first, let name = pieceNames[piece] {
                promotionWord = ", promotes to \(name)"
            }
            text = String(text[..<eqRange.lowerBound])
        }

        let verb = isCapture ? "takes on" : "to"
        return "\(pieceWord) \(verb) \(text)\(promotionWord)\(suffix)"
    }
}
