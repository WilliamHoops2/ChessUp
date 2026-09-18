//
//  GridRefiner.swift
//  ChessUp
//
//  Created by William Silvano Angga on 18/09/26.
//

import CoreVideo
import CoreGraphics

struct BoardGrid {
    var fileLines: [CGFloat]
    var rankLines: [CGFloat]

    static var uniform: BoardGrid {
        let lines = (0...8).map { CGFloat($0) / 8 }
        return BoardGrid(fileLines: lines, rankLines: lines)
    }

    static func squareIndex(for value: CGFloat, in lines: [CGFloat]) -> Int {
        for i in 0..<8 {
            if value >= lines[i] && value < lines[i + 1] {
                return i
            }
        }
        return value < lines[0] ? 0 : 7
    }

    func cellRect(file: Int, rank: Int, in extent: CGRect) -> CGRect {
        let x0 = extent.origin.x + fileLines[file] * extent.width
        let x1 = extent.origin.x + fileLines[file + 1] * extent.width
        let y0 = extent.origin.y + rankLines[rank] * extent.height
        let y1 = extent.origin.y + rankLines[rank + 1] * extent.height
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

enum GridRefiner {

    private static let searchFraction: CGFloat = 0.3
    private static let minPeakToMeanRatio: Float = 1.4

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

        var colProfile = [Float](repeating: 0, count: width)
        for x in 1..<(width - 1) {
            var sum: Float = 0
            for y in 0..<height {
                sum += abs(luma(x + 1, y) - luma(x - 1, y))
            }
            colProfile[x] = sum
        }

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
        let rankLines = (0...8).map { k in 1 - CGFloat(rasterRows[8 - k]) / CGFloat(height) }

        return BoardGrid(fileLines: fileLines, rankLines: rankLines)
    }

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

            lines[k] = (mean > 0 && bestV >= mean * minPeakToMeanRatio) ? bestX : Int(expected)
        }
        return lines
    }
}
