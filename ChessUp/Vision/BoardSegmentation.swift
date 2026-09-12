//
//  BoardSegmentation.swift
//  ChessUp
//
//  Created by William Silvano Angga on 12/09/26.
//
//  Decodes the raw output of `board-model` (YOLOv11m-seg, from
//  github.com/oliverfrost1/chess-video-move-detection, MIT license)
//  into four board corners, and warps a camera frame to a top-down
//  view using those corners.
//
//  This only needs to run once, at calibration time — see
//  `CoreMLBoardDetector.calibrate(pixelBuffer:)`. The board doesn't
//  move once the phone is propped up; only the pieces do.
//

import CoreImage
import CoreML

/// Four corners of the physical board in a frame's pixel space
/// (origin top-left, y-down — standard image/Vision convention).
struct BoardCorners {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint
}

extension BoardCorners: CustomStringConvertible {
    var description: String {
        func fmt(_ p: CGPoint) -> String { "(\(Int(p.x)),\(Int(p.y)))" }
        return "TL\(fmt(topLeft)) TR\(fmt(topRight)) BR\(fmt(bottomRight)) BL\(fmt(bottomLeft))"
    }
}

/// Result of a successful board-segmentation decode: the corners plus
/// the raw detection score, so callers can log/tune confidence.
struct BoardDetectionResult {
    var corners: BoardCorners
    var confidence: Float
}

enum BoardSegmentationError: Error {
    case noDetection
    case decodeFailure
    case unexpectedOutputShape
}

enum BoardSegmentationDecoder {

    /// board-model output tensors (imgsz=640, 1 class "chess_board"):
    ///   raw:   [1, 37, 8400]    -> per anchor: 4 box coords + 1 objectness + 32 mask coeffs
    ///   proto: [1, 32, 160, 160] -> mask prototypes
    static func decode(raw: MLMultiArray, proto: MLMultiArray, maskThreshold: Float = 0.5) throws -> BoardDetectionResult {
        guard raw.dataType == .float32, proto.dataType == .float32 else {
            throw BoardSegmentationError.unexpectedOutputShape
        }
        let numAttrs = raw.shape[1].intValue
        let numAnchors = raw.shape[2].intValue
        guard numAttrs == 37 else { throw BoardSegmentationError.unexpectedOutputShape }

        let rawPtr = raw.dataPointer.bindMemory(to: Float32.self, capacity: raw.count)
        let rawStride = raw.strides.map { $0.intValue }
        func rawValue(_ attr: Int, _ anchor: Int) -> Float {
            rawPtr[attr * rawStride[1] + anchor * rawStride[2]]
        }

        // Single class, so "best detection" is just the highest-objectness anchor.
        var bestAnchor = 0
        var bestScore: Float = -.infinity
        for a in 0..<numAnchors {
            let score = rawValue(4, a)
            if score > bestScore {
                bestScore = score
                bestAnchor = a
            }
        }
        guard bestScore > 0 else { throw BoardSegmentationError.noDetection }

        var coeffs = [Float](repeating: 0, count: 32)
        for c in 0..<32 {
            coeffs[c] = rawValue(5 + c, bestAnchor)
        }

        guard proto.shape.count == 4 else { throw BoardSegmentationError.unexpectedOutputShape }
        let maskSize = proto.shape[2].intValue // 160
        let protoPtr = proto.dataPointer.bindMemory(to: Float32.self, capacity: proto.count)
        let protoStride = proto.strides.map { $0.intValue }

        var maskPoints: [CGPoint] = []
        maskPoints.reserveCapacity((maskSize * maskSize) / 4)
        let modelInputSize: CGFloat = 640
        let scale = modelInputSize / CGFloat(maskSize)

        for y in 0..<maskSize {
            for x in 0..<maskSize {
                var sum: Float = 0
                for c in 0..<32 {
                    sum += coeffs[c] * protoPtr[c * protoStride[1] + y * protoStride[2] + x * protoStride[3]]
                }
                if 1 / (1 + exp(-sum)) > maskThreshold {
                    maskPoints.append(CGPoint(x: CGFloat(x) * scale, y: CGFloat(y) * scale))
                }
            }
        }
        guard maskPoints.count > 8 else { throw BoardSegmentationError.decodeFailure }

        return BoardDetectionResult(corners: corners(from: maskPoints), confidence: bestScore)
    }

    /// Heuristic corner extraction: for a roughly-rectangular (possibly
    /// rotated) mask, the four corners are well approximated by the
    /// points that extremize (x+y) and (x-y). Simpler than a full
    /// convex-hull + polygon-simplification pass, and good enough for
    /// the "phone propped up at a moderate angle" framing ChessUp
    /// targets. If very steep/oblique angles turn out to need it,
    /// swap this for a proper minimum-area-rectangle fit.
    private static func corners(from points: [CGPoint]) -> BoardCorners {
        var topLeft = points[0], bottomRight = points[0]
        var topRight = points[0], bottomLeft = points[0]
        var minSum = points[0].x + points[0].y
        var maxSum = minSum
        var minDiff = points[0].x - points[0].y
        var maxDiff = minDiff

        for p in points {
            let sum = p.x + p.y
            let diff = p.x - p.y
            if sum < minSum { minSum = sum; topLeft = p }
            if sum > maxSum { maxSum = sum; bottomRight = p }
            if diff > maxDiff { maxDiff = diff; topRight = p }
            if diff < minDiff { minDiff = diff; bottomLeft = p }
        }
        return BoardCorners(topLeft: topLeft, topRight: topRight, bottomRight: bottomRight, bottomLeft: bottomLeft)
    }
}

/// Warps a frame to a top-down view of the board using calibrated corners.
enum PerspectiveWarp {
    /// - Parameters:
    ///   - image: the full camera frame.
    ///   - corners: board corners in 640x640 model-input pixel space
    ///     (y-down), as produced by `BoardSegmentationDecoder`.
    static func warp(_ image: CIImage, corners: BoardCorners, modelInputSize: CGFloat = 640) -> CIImage? {
        // CIPerspectiveCorrection wants points in the source image's
        // own Core Image space (y-up, matches `image.extent`), so
        // scale from model space to the image's actual pixel size and
        // flip y.
        let sx = image.extent.width / modelInputSize
        let sy = image.extent.height / modelInputSize
        func toCI(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * sx, y: image.extent.height - (p.y * sy))
        }

        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: toCI(corners.topLeft)), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: toCI(corners.topRight)), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: toCI(corners.bottomRight)), forKey: "inputBottomRight")
        filter.setValue(CIVector(cgPoint: toCI(corners.bottomLeft)), forKey: "inputBottomLeft")
        return filter.outputImage
    }
}
