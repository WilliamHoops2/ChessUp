//
//  OccupancyClassifier.swift
//  ChessUp
//
//  Created by William Silvano Angga on 18/09/26.
//

import CoreImage
import ChessKit

final class OccupancyClassifier {
    private struct ColorSample {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
    }

    private struct Candidate {
        let file: Int
        let rank: Int
        let isWhite: Bool
        let margin: CGFloat
        let sample: ColorSample
    }

    private var baselines: [[ColorSample]]?
    private let ciContext: CIContext

    private var isAccumulating = false
    private var accumulatingSums: [[ColorSample]] = []
    private var accumulatingCounts: [[Int]] = []
    private var framesAccumulated = 0
    private let framesRequiredForCalibration = 5

    private let minMarginToClassifyAsOccupied: CGFloat = 0.002

    private let maxPlausibleOccupied = 32

    init(ciContext: CIContext) {
        self.ciContext = ciContext
    }

    var isCalibrated: Bool { baselines != nil }
    var isCalibrationInProgress: Bool { isAccumulating }

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

    func invalidate() {
        baselines = nil
        isAccumulating = false
        framesAccumulated = 0
    }

    func classify(warpedImage: CIImage, grid: BoardGrid) -> (state: BoardState, debug: [PieceDetectionDebug])? {
        guard let baselines else { return nil }

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

        let accepted: Set<Int>
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

    private func weightedSquaredDistance(_ a: ColorSample, _ b: ColorSample) -> CGFloat {
        let dr = a.r - b.r, dg = a.g - b.g, db = a.b - b.b
        return 0.299 * dr * dr + 0.587 * dg * dg + 0.114 * db * db
    }
}
