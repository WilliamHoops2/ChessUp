//
//  BoardSegmentation.swift
//  ChessUp
//
//  Created by William Silvano Angga on 15/09/26.
//

import CoreImage
import CoreML

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

struct BoardDetectionResult {
    var corners: BoardCorners
    var cornerConfidences: [Float]
    var segmentationConfidence: Float
}

enum BoardSegmentationError: Error {
    case noDetection
    case decodeFailure
    case unexpectedOutputShape
}

enum CornerHeatmapDecoder {

    static func decode(
        cornerHeatmap: MLMultiArray,
        segmentation: MLMultiArray,
        cropRect: CGRect
    ) throws -> BoardDetectionResult {
        guard cornerHeatmap.dataType == .float32, segmentation.dataType == .float32 else {
            throw BoardSegmentationError.unexpectedOutputShape
        }
        guard cornerHeatmap.shape.count == 4, cornerHeatmap.shape[3].intValue == 4 else {
            throw BoardSegmentationError.unexpectedOutputShape
        }
        let heatmapSize = cornerHeatmap.shape[1].intValue // 128
        let stride = cornerHeatmap.strides.map { $0.intValue }
        let ptr = cornerHeatmap.dataPointer.bindMemory(to: Float32.self, capacity: cornerHeatmap.count)

        func value(_ channel: Int, _ y: Int, _ x: Int) -> Float {
            ptr[y * stride[1] + x * stride[2] + channel * stride[3]]
        }

        var points: [CGPoint] = []
        var confidences: [Float] = []
        for channel in 0..<4 {
            var best: Float = -.infinity
            var bestX = 0, bestY = 0
            for y in 0..<heatmapSize {
                for x in 0..<heatmapSize {
                    let v = value(channel, y, x)
                    if v > best {
                        best = v
                        bestX = x
                        bestY = y
                    }
                }
            }
            confidences.append(best)
            let fracX = (CGFloat(bestX) + 0.5) / CGFloat(heatmapSize)
            let fracY = (CGFloat(bestY) + 0.5) / CGFloat(heatmapSize)
            let framePoint = CGPoint(
                x: cropRect.origin.x + fracX * cropRect.width,
                y: cropRect.origin.y + fracY * cropRect.height
            )
            points.append(framePoint)
        }

        guard points.count == 4 else { throw BoardSegmentationError.decodeFailure }

        let corners = BoardCorners(topLeft: points[0], topRight: points[1], bottomRight: points[2], bottomLeft: points[3])

        let segPtr = segmentation.dataPointer.bindMemory(to: Float32.self, capacity: segmentation.count)
        var segSum: Float = 0
        for i in 0..<segmentation.count { segSum += segPtr[i] }
        let segMean = segmentation.count > 0 ? segSum / Float(segmentation.count) : 0

        return BoardDetectionResult(corners: corners, cornerConfidences: confidences, segmentationConfidence: segMean)
    }
}

enum PerspectiveWarp {
    static func warp(_ image: CIImage, corners: BoardCorners) -> CIImage? {
        func toCI(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x, y: image.extent.height - p.y)
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
