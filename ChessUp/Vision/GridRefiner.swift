//
//  GridRefiner.swift
//  ChessUp
//
//  Defines BoardGrid — the 8x8 grid-line positions within a warped,
//  top-down board crop — and refines those 9+9 line positions using
//  real edge-gradient peaks in the warped image, rather than assuming
//  a perfectly uniform /8 split.
//
//  WHY NOT A FULL HOUGH TRANSFORM: classic Hough line detection solves
//  "find lines at unknown angles" — essential when a board is tilted
//  in a raw photo, which is exactly what CoreMLBoardDetector's
//  corner-heatmap model already handles. By the time an image reaches
//  this code, PerspectiveWarp has already made the board fronto-
//  parallel: the 9 grid lines are perfectly axis-aligned by
//  construction. What's actually needed is just "where exactly, along
//  this known axis, does each line sit" — a 1-D peak-finding problem,
//  cheaper and more direct than 2-D Hough voting for this specific
//  case: sum edge strength along each column/row to get a profile,
//  then find the peak near each expected uniform-grid position.
//
//  This matters beyond just drawing a prettier debug grid:
//  OccupancyClassifier samples each cell's average color from a rect
//  computed via `cellRect(file:rank:in:)`, which reads directly off
//  `fileLines`/`rankLines`. If those line positions drift because the
//  warp isn't pixel-perfect, every sample box drifts with them — which
//  can pull in a neighboring square's color (or a piece's base) right
//  at the boundary, a real contributor to occupancy misclassification.
//  A permanently-`.uniform` placeholder silently reintroduces that
//  risk, which is why this file computes real line positions instead.
//
//  Chess-specific assumption this leans on: because squares alternate
//  color in both directions, every interior grid line separates a
//  light square from a dark square somewhere along its length — so
//  even with pieces sitting on some squares, each line still produces
//  a real, findable contrast edge across most of its length.
//

import CoreVideo
import CoreGraphics

/// Normalized (0...1) grid-line positions within a warped board crop,
/// in CoreImage's own coordinate convention (origin bottom-left,
/// y-up) — matching Vision's bounding-box convention directly, which
/// is why `detectPieces`/`OccupancyClassifier` can feed raw normalized
/// coordinates into `squareIndex` without any flip.
struct BoardGrid {
    /// 9 positions (0 boundary + 8 cell edges + 1 boundary... i.e.
    /// fileLines[0] = 0, fileLines[8] = 1) marking the 8 file cell
    /// boundaries along x.
    var fileLines: [CGFloat]
    /// Same, along y.
    var rankLines: [CGFloat]

    static var uniform: BoardGrid {
        let lines = (0...8).map { CGFloat($0) / 8 }
        return BoardGrid(fileLines: lines, rankLines: lines)
    }

    /// Maps a normalized coordinate (0...1) to a 0...7 cell index,
    /// given that axis's line positions.
    static func squareIndex(for value: CGFloat, in lines: [CGFloat]) -> Int {
        for i in 0..<8 {
            if value >= lines[i] && value < lines[i + 1] {
                return i
            }
        }
        return value < lines[0] ? 0 : 7
    }

    /// The pixel-space rect for a given (file, rank) cell within an
    /// image of the given extent (e.g. a warped board crop's own
    /// `.extent`).
    func cellRect(file: Int, rank: Int, in extent: CGRect) -> CGRect {
        let x0 = extent.origin.x + fileLines[file] * extent.width
        let x1 = extent.origin.x + fileLines[file + 1] * extent.width
        let y0 = extent.origin.y + rankLines[rank] * extent.height
        let y1 = extent.origin.y + rankLines[rank + 1] * extent.height
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

enum GridRefiner {

    /// Fraction of a cell's width/height to search on either side of
    /// each expected uniform-grid line position. Wide enough to
    /// absorb realistic warp imperfection, narrow enough to stay
    /// clear of neighboring lines (any more than ~0.4 risks
    /// overlapping the search window for the adjacent line).
    private static let searchFraction: CGFloat = 0.3

    /// A candidate peak must beat the profile's own mean by at least
    /// this factor to be trusted over the uniform fallback position —
    /// guards against snapping to a piece silhouette's edge on a
    /// mostly-featureless line instead of the actual grid line.
    private static let minPeakToMeanRatio: Float = 1.4

    /// `pixelBuffer` should be the rendered warped top-down board crop
    /// (kCVPixelFormatType_32BGRA — the format `CoreMLBoardDetector`'s
    /// `render(_:)` always produces). Returns `.uniform` for any format
    /// it doesn't recognize or any buffer too small to be meaningful,
    /// so a refinement failure degrades to the old safe behavior
    /// rather than crashing or producing garbage line positions.
    static func refine(pixelBuffer: CVPixelBuffer) -> BoardGrid {
        guard
            CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA
        else {
            return .uniform
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return .uniform }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 16, height > 16 else { return .uniform }

        let ptr = base.assumingMemoryBound(to: UInt8.self)

        @inline(__always) func luma(_ x: Int, _ y: Int) -> Float {
            let offset = y * bytesPerRow + x * 4
            let b = Float(ptr[offset])
            let g = Float(ptr[offset + 1])
            let r = Float(ptr[offset + 2])
            return 0.114 * b + 0.587 * g + 0.299 * r
        }

        // colProfile[x]: total horizontal-gradient strength at column x,
        // summed down every row — spikes at vertical grid lines.
        var colProfile = [Float](repeating: 0, count: width)
        for x in 1..<(width - 1) {
            var sum: Float = 0
            for y in 0..<height {
                sum += abs(luma(x + 1, y) - luma(x - 1, y))
            }
            colProfile[x] = sum
        }

        // rowProfile[y]: same idea, vertical-gradient strength summed
        // across every column — spikes at horizontal grid lines.
        var rowProfile = [Float](repeating: 0, count: height)
        for y in 1..<(height - 1) {
            var sum: Float = 0
            for x in 0..<width {
                sum += abs(luma(x, y + 1) - luma(x, y - 1))
            }
            rowProfile[y] = sum
        }

        let rasterCols = refinedLines(profile: colProfile, length: width)
        let rasterRows = refinedLines(profile: rowProfile, length: height)

        let fileLines = rasterCols.map { CGFloat($0) / CGFloat(width) }
        // Flip top-left/y-down raster rows into this file's bottom-left/
        // y-up normalized convention: rankLines[k] corresponds to
        // rasterRows[8-k].
        let rankLines = (0...8).map { k in 1 - CGFloat(rasterRows[8 - k]) / CGFloat(height) }

        return BoardGrid(fileLines: fileLines, rankLines: rankLines)
    }

    /// Given a 1-D edge-strength profile, returns the 9 line positions
    /// (0, refined 1...7, `length`) in raster (pixel index) space.
    private static func refinedLines(profile: [Float], length: Int) -> [Int] {
        let cellSize = Float(length) / 8
        let mean = profile.reduce(0, +) / Float(max(profile.count, 1))

        var lines = [Int](repeating: 0, count: 9)
        lines[0] = 0
        lines[8] = length
        for k in 1...7 {
            let expected = Float(k) * cellSize
            let window = cellSize * Float(searchFraction)
            let lo = max(1, Int(expected - window))
            let hi = min(length - 2, Int(expected + window))
            guard lo < hi else { lines[k] = Int(expected); continue }

            var bestX = Int(expected)
            var bestV: Float = -.infinity
            for x in lo...hi where profile[x] > bestV {
                bestV = profile[x]
                bestX = x
            }

            // Only trust the peak if it's a genuine standout — otherwise
            // this line probably sits on a mostly-featureless stretch
            // (e.g. two pieces of similar tone straddling it) and the
            // uniform position is the safer guess.
            lines[k] = (mean > 0 && bestV >= mean * minPeakToMeanRatio) ? bestX : Int(expected)
        }
        return lines
    }
}
