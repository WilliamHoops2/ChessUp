//
//  SpeechAnnouncer.swift
//  ChessUp
//
//  Created by William Silvano Angga on 12/09/26.
//
//  Converts a move into a spoken phrase the human can act on without
//  looking at the screen — the whole point of this app is that the
//  user is looking at the physical board, not their phone.
//

import AVFoundation

final class SpeechAnnouncer: NSObject {
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        // Without this, AVSpeechSynthesizer's audio respects the
        // hardware mute switch by default (the system treats it like
        // ambient/incidental sound), so announcements can silently not
        // play at all depending on the switch position — easy to miss
        // while testing if the phone happens to be unmuted. `.playback`
        // is the category for audio that's the deliberate point of the
        // app (this app's entire premise is—don't look at the phone,
        // listen to it), so it should always play.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[ChessUp Speech] ⚠️ failed to configure audio session: \(error) — announcements may not play if the phone is muted")
        }
    }

    /// Takes a plain SAN string (e.g. "Nf3", "exd5", "O-O") rather than
    /// an EngineMove — speech doesn't need to know anything about the
    /// engine, just the move that was actually applied to the board.
    func announce(sanMove: String) {
        let phrase = spokenPhrase(for: sanMove)
        let utterance = AVSpeechUtterance(string: phrase)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        synthesizer.speak(utterance)
    }

    /// Turns SAN like "Nf3", "exd5", "O-O", "e8=Q+" into something
    /// natural to say aloud. This is a first pass covering the common
    /// cases — expand piece/square pronunciation as you test with real
    /// games (e.g. deciding whether "check" and "checkmate" should be
    /// appended, whether captures say "takes").
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

        // Promotion, e.g. "e8=Q"
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
