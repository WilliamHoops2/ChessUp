# ChessUp — Architecture & Setup

## What's here

A scaffold for the full pipeline described in the app spec:

```
Camera (AVFoundation)
   -> BoardDetector (Vision/CoreML)        [not implemented yet — see below]
   -> BoardState snapshots
   -> MoveDetector (diffs snapshots into a move, debounced for stability)
   -> GameSession (turn state, applies move, asks engine for reply)
   -> ChessEngineManager (Stockfish via ChessKitEngine)
   -> SpeechAnnouncer (AVSpeechSynthesizer reads the bot's move aloud)
```

Everything except the vision model is real, structured Swift — not
placeholder text. The vision model is the one part that genuinely
needs training data and can't be conjured; see `Vision/BoardDetector.swift`
for the recommended path (fine-tune an existing open-source YOLO
chess-piece model, convert to Core ML) and `MockBoardDetector` for
testing everything else without a camera in the meantime.

## Required setup in Xcode (can't be done by editing files directly)

1. **Add Swift Package dependencies** — File > Add Package Dependencies:
   - `https://github.com/chesskit-app/chesskit-engine` (Stockfish via UCI, MIT license)
   - `https://github.com/chesskit-app/chesskit-swift` (chess rules/FEN/SAN, check its license file)

   Then uncomment the `import ChessKit` / `import ChessKitEngine` lines
   in `GameSession.swift`, `MoveDetector.swift`, and
   `ChessEngineManager.swift`, and fill in the `TODO`s — they're
   sketched against the package's public API from its README, but
   double check exact method/enum names against the current version,
   since package APIs do shift between releases.

   Also check chesskit-engine's README "Neural Networks" section — it
   calls out required NNUE eval file setup, don't skip it.

2. **Add camera permission** to `Info.plist`:
   `NSCameraUsageDescription` = "ChessUp uses the camera to read the board and pieces during play."

3. **Add speech permission is not required** for `AVSpeechSynthesizer`
   output (only speech *recognition* needs a permission), so no extra
   Info.plist entry needed there.

## The one open licensing question

Stockfish is GPL-3.0. On iOS you can't spawn it as a separate process
(sandboxing), so it has to be compiled directly into your app binary —
which, per Stockfish's own project maintainers, brings your app under
GPL too if you distribute it. This doesn't block building or testing
the app, but it's worth resolving *before* you publish to the App
Store: either plan to ship ChessUp as source-available/GPL, or revisit
the engine choice (there are weaker non-GPL options, but none match
Stockfish's strength or its free NNUE evals).

## Suggested build order

1. Get `MockBoardDetector` driving the full loop end-to-end: setup ->
   simulated human move -> Stockfish reply -> spoken announcement ->
   next simulated move. This validates GameSession, the engine
   wrapper, and speech without touching computer vision at all.
2. Wire in a camera preview (`CameraManager` is ready) just to get
   comfortable with the phone-above-board framing/angle in practice.
3. Tackle the vision model: start from one of the open-source YOLO
   chess models referenced in `BoardDetector.swift`, convert to Core
   ML, and get it correctly reading your actual physical board and
   piece set — this step will take the most iteration, since accuracy
   depends heavily on your specific board/pieces/lighting/angle.
4. Swap `MockBoardDetector` for `CoreMLBoardDetector` once it's
   reliable, and add the board-calibration overlay (drag the 4
   corners) so the angled-phone setup in your spec actually works.
