//
//  OccupancyClassifier.swift
//  ChessUp
//
//  Classifies each of the 64 grid cells on a warped top-down board
//  crop as empty / white / black, using a color-based heuristic rather
//  than a trained model — see the architecture note in
//  CoreMLBoardDetector.swift for why a full 12-class piece-classifier
//  model isn't used anymore at all.
//
//  Self-calibrates from the very first frame after board calibration
//  completes, since — by the rules of chess — that frame IS the
//  standard starting position: 16 white-occupied squares, 16
//  black-occupied squares, 32 empty squares, in exactly known
//  locations. Sampling real pixel colors from THOSE known squares, on
//  THIS specific board/lighting/camera, gives a much more reliable
//  baseline than any fixed threshold tuned on a different board/photo
//  ever could — and it's the same "we already know the starting
//  position" insight the whole simplified vision approach is built on.
//

import CoreImage
import ChessKit

final class OccupancyClassifier {
    private struct ColorSample {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
    }

    /// A candidate square's occupancy call, kept around only long
    /// enough to apply the global top-32 cap below.
    private struct Candidate {
        let file: Int
        let rank: Int
        let isWhite: Bool
        let margin: CGFloat   // distToEmpty - bestPieceDist; larger = more confident
        let sample: ColorSample
    }

    // Indexed [boardSquareColorClass: 0 or 1][occupantClass: 0=empty, 1=white, 2=black]
    private var baselines: [[ColorSample]]?
    private let ciContext: CIContext

    // MARK: - Multi-frame calibration accumulation
    // Mirrors CoreMLBoardDetector's corner-consensus approach: average
    // several consecutive frames rather than trusting a single one, so
    // a lighting flicker, tiny hand tremor, or one slightly-blurry
    // frame can't singlehandedly define the baseline every future
    // frame gets judged against. This ALSO used to run automatically
    // on the very first clean frame after corner lock-in — the actual
    // bug behind under/over-counting turned out to be that corner
    // lock-in has nothing to do with whether the player has actually
    // finished placing all 32 pieces yet (corners are visible on an
    // empty board too), so calibration could fire against a
    // half-set-up board. Now it only starts when `beginCalibration()`
    // is explicitly called — wire that to a "my board is set up" button
    // (see CoreMLBoardDetector.confirmPiecesReady()).
    private var isAccumulating = false
    private var accumulatingSums: [[ColorSample]] = []
    private var accumulatingCounts: [[Int]] = []
    private var framesAccumulated = 0
    private let framesRequiredForCalibration = 5

    /// How much closer a piece baseline (white or black) must be than
    /// the empty baseline before a square is even a CANDIDATE for
    /// "occupied", rather than defaulting to empty outright. This
    /// operates on a luma-weighted squared-distance scale (see
    /// `weightedSquaredDistance`) — channels are weighted the same way
    /// as GridRefiner's edge detection (0.299R/0.587G/0.114B), since
    /// piece-vs-board contrast is overwhelmingly a brightness
    /// difference, and weighting that way is less sensitive to a
    /// single noisy/oversaturated channel (glare, warm lighting) than
    /// plain unweighted RGB distance was.
    ///
    /// This alone doesn't guarantee ≤32 occupied squares — it just
    /// makes each individual call more conservative. The hard
    /// guarantee is `maxPlausibleOccupied` below; this margin is what
    /// keeps that cap from having to do all the work by itself.
    ///
    /// Main knob to tune once you can see it against a real board:
    /// raise it if real pieces are getting missed and this is
    /// defaulting too many of them to empty, lower it if it's
    /// rejecting clearly-occupied squares as "not confident enough".
    ///
    /// Deliberately loose: `maxPlausibleOccupied` below is what
    /// actually guarantees no more than 32 squares are ever reported
    /// as occupied, so this margin doesn't need to (and shouldn't)
    /// also carry that responsibility — its only job is "is this
    /// square closer to a piece baseline than to empty at all". A
    /// stricter value here just risks rejecting real pieces as
    /// candidates before the cap even gets a chance to rank them.
    private let minMarginToClassifyAsOccupied: CGFloat = 0.002

    /// Hard structural ceiling: a legal chess position can never have
    /// more than 32 pieces on the board. If more than this many
    /// squares individually clear `minMarginToClassifyAsOccupied` in a
    /// single frame — camera noise, a shadow, board grain all looking
    /// piece-like on a handful of squares — that's proof at least some
    /// of those calls are wrong, since the true count is physically
    /// bounded. Rather than trust every individual call, only the 32
    /// squares with the STRONGEST margins are kept as "occupied"; the
    /// rest are downgraded to empty. This is what makes "detects 40-50
    /// pieces" structurally impossible regardless of how well-tuned
    /// the per-square margin above is.
    private let maxPlausibleOccupied = 32

    init(ciContext: CIContext) {
        self.ciContext = ciContext
    }

    var isCalibrated: Bool { baselines != nil }
    var isCalibrationInProgress: Bool { isAccumulating }

    /// Starts (or restarts) the multi-frame calibration process. Call
    /// once the user confirms the board is fully set up in the
    /// standard starting position and the phone is holding steady —
    /// from then on, feed frames via `accumulateCalibrationFrame`.
    func beginCalibration() {
        isAccumulating = true
        accumulatingSums = [
            [ColorSample(), ColorSample(), ColorSample()],
            [ColorSample(), ColorSample(), ColorSample()]
        ]
        accumulatingCounts = [[0, 0, 0], [0, 0, 0]]
        framesAccumulated = 0
        baselines = nil
    }

    /// Feed one frame while calibration is in progress. Returns true
    /// the moment enough frames have been accumulated and `baselines`
    /// is finalized (from then on `classify` works normally); calling
    /// this again afterward, or before `beginCalibration()` was ever
    /// called, is a harmless no-op that just reports current status.
    /// This assumes the physical board is in the standard starting
    /// position for the whole accumulation window — true as long as
    /// the player doesn't touch the board between confirming and the
    /// last accumulated frame, which takes under a couple seconds.
    @discardableResult
    func accumulateCalibrationFrame(warpedImage: CIImage, grid: BoardGrid) -> Bool {
        guard isAccumulating else { return baselines != nil }

        for file in 0..<8 {
            for rank in 0..<8 {
                let occupant = BoardState.startingPosition[file, rank]
                let colorClass = (file + rank) % 2
                let occupantClass: Int
                switch occupant {
                case .empty: occupantClass = 0
                case .piece(.white): occupantClass = 1
                case .piece(.black): occupantClass = 2
                }
                let sample = averageColor(in: warpedImage, file: file, rank: rank, grid: grid)
                accumulatingSums[colorClass][occupantClass].r += sample.r
                accumulatingSums[colorClass][occupantClass].g += sample.g
                accumulatingSums[colorClass][occupantClass].b += sample.b
                accumulatingCounts[colorClass][occupantClass] += 1
            }
        }
        framesAccumulated += 1
        guard framesAccumulated >= framesRequiredForCalibration else { return false }

        var averaged = accumulatingSums
        for c in 0..<2 {
            for o in 0..<3 {
                let n = max(accumulatingCounts[c][o], 1)
                averaged[c][o].r /= CGFloat(n)
                averaged[c][o].g /= CGFloat(n)
                averaged[c][o].b /= CGFloat(n)
            }
        }
        baselines = averaged
        isAccumulating = false
        return true
    }

    /// Explicit re-calibration hook, in case lighting changes mid-game
    /// (e.g. a lamp switches on) and classification starts drifting.
    /// Not wired to any UI trigger yet — here for when it's needed.
    func invalidate() {
        baselines = nil
        isAccumulating = false
        framesAccumulated = 0
    }

    /// Returns nil if `calibrate` hasn't been called yet — callers
    /// should treat that the same as "not confident enough", not
    /// assume an empty board.
    func classify(warpedImage: CIImage, grid: BoardGrid) -> (state: BoardState, debug: [PieceDetectionDebug])? {
        guard let baselines else { return nil }

        // Pass 1: score every one of the 64 squares independently.
        var candidates: [Candidate] = []
        candidates.reserveCapacity(32)

        for file in 0..<8 {
            for rank in 0..<8 {
                let colorClass = (file + rank) % 2
                let sample = averageColor(in: warpedImage, file: file, rank: rank, grid: grid)
                let baseline = baselines[colorClass]
                let distToEmpty = weightedSquaredDistance(baseline[0], sample)
                let distToWhite = weightedSquaredDistance(baseline[1], sample)
                let distToBlack = weightedSquaredDistance(baseline[2], sample)
                let bestPieceIsWhite = distToWhite <= distToBlack
                let bestPieceDist = min(distToWhite, distToBlack)
                let margin = distToEmpty - bestPieceDist

                if margin > minMarginToClassifyAsOccupied {
                    candidates.append(Candidate(file: file, rank: rank, isWhite: bestPieceIsWhite, margin: margin, sample: sample))
                }
            }
        }

        // Pass 2: enforce the hard ≤32 ceiling. Only the strongest
        // `maxPlausibleOccupied` candidates survive as genuinely
        // "occupied" — see `maxPlausibleOccupied`'s doc comment for why
        // this is a real chess-rule invariant, not an arbitrary cap.
        let accepted: Set<Int>  // encoded as file*8+rank for cheap lookup
        if candidates.count > maxPlausibleOccupied {
            let strongest = candidates.sorted { $0.margin > $1.margin }.prefix(maxPlausibleOccupied)
            accepted = Set(strongest.map { $0.file * 8 + $0.rank })
        } else {
            accepted = Set(candidates.map { $0.file * 8 + $0.rank })
        }

        var state = BoardState()
        var debug: [PieceDetectionDebug] = []
        for candidate in candidates where accepted.contains(candidate.file * 8 + candidate.rank) {
            let occupant: Occupant = .piece(candidate.isWhite ? .white : .black)
            state[candidate.file, candidate.rank] = occupant

            // Rough, unitless "confidence" for the debug overlay —
            // purely visual, not a calibrated probability.
            let confidence = Float(max(0, min(1, candidate.margin * 10)))
            let cellRect = grid.cellRect(file: candidate.file, rank: candidate.rank, in: warpedImage.extent)
            let normalizedBox = CGRect(
                x: cellRect.origin.x / warpedImage.extent.width,
                y: cellRect.origin.y / warpedImage.extent.height,
                width: cellRect.width / warpedImage.extent.width,
                height: cellRect.height / warpedImage.extent.height
            )
            debug.append(PieceDetectionDebug(
                label: candidate.isWhite ? "white" : "black",
                confidence: confidence,
                boundingBox: normalizedBox
            ))
        }
        return (state, debug)
    }

    // MARK: - Sampling

    /// Samples the central ~40% of a grid cell — small enough to avoid
    /// a piece's shadow or a neighboring piece spilling in from an
    /// adjacent square, large enough to average out noise/specular
    /// highlights on a single piece. Uses CIAreaAverage (GPU-accelerated)
    /// rather than manually reading pixels.
    private func averageColor(in image: CIImage, file: Int, rank: Int, grid: BoardGrid) -> ColorSample {
        let cellRect = grid.cellRect(file: file, rank: rank, in: image.extent)
        let inset = cellRect.insetBy(dx: cellRect.width * 0.3, dy: cellRect.height * 0.3)

        guard let filter = CIFilter(name: "CIAreaAverage") else { return ColorSample() }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: inset), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return ColorSample() }

        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            output, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: nil
        )
        return ColorSample(
            r: CGFloat(pixel[0]) / 255,
            g: CGFloat(pixel[1]) / 255,
            b: CGFloat(pixel[2]) / 255
        )
    }

    /// Squared distance with channels weighted by the standard luma
    /// coefficients (0.299R / 0.587G / 0.114B) rather than plain
    /// unweighted RGB distance. Piece-vs-board contrast is
    /// overwhelmingly a brightness (luma) difference — a cream/white
    /// piece and a black piece both differ from a mid-tone wood square
    /// mostly in how light or dark they are, not in hue — so weighting
    /// toward luma makes the metric track the signal that actually
    /// separates the three classes, and dampens the influence of a
    /// single channel getting thrown off by warm lighting or glare.
    private func weightedSquaredDistance(_ a: ColorSample, _ b: ColorSample) -> CGFloat {
        let dr = a.r - b.r, dg = a.g - b.g, db = a.b - b.b
        return 0.299 * dr * dr + 0.587 * dg * dg + 0.114 * db * db
    }
}
