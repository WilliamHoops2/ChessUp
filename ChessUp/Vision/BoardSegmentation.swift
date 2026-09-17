//
//  BoardSegmentation.swift
//  ChessUp
//
//  Created by William Silvano Angga on 15/09/26.
//
//  Decodes board-corner detection output and warps a camera frame to
//  a top-down view using those corners.
//
//  Model: github.com/Elucidation/chessdetect-tfjs (MIT license) — a
//  U-Net++ that takes a 128x128 center-square crop of the frame and
//  outputs a 1-channel board segmentation mask plus a 4-channel
//  "corner heatmap" (one channel per corner, each a Gaussian blob
//  peaking at that corner's location). This replaces the earlier
//  approach (github.com/oliverfrost1/chess-video-move-detection's
//  board-model), which scored 0.11-0.19 confidence on real photos of
//  this board — this model scores 0.9998-1.0 on segmentation and
//  0.4-0.8+ on corner peaks for the same photos.
//
//  This only needs to run once, at calibration time — see
//  `CoreMLBoardDetector.calibrate(pixelBuffer:)`. The board doesn't
//  move once the phone is propped up; only the pieces do.
//
//  IMPORTANT: this model's own preprocessing (see chessdetect-tfjs's
//  script.js) is a CENTER-SQUARE CROP of the frame, then resize to
//  128x128 — not a plain resize. Vision's `.centerCrop` image option
//  (set on the VNCoreMLRequest in CoreMLBoardDetector) replicates this
//  exactly, and `CornerHeatmapDecoder` below assumes that crop when it
//  maps a heatmap coordinate back to the original frame's pixel space.
//  If a board's corner sits outside that center square (e.g. a
//  portrait-orientation photo where the board is wider than it is
//  tall), that corner gets cropped out of the model's view entirely —
//  frame the shot so the board fits within a center square region.
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

/// Result of a successful corner decode: the corners plus each
/// corner's individual peak confidence (in TL, TR, BR, BL order) so
/// callers can log/tune per-corner reliability — a corner clipped by
/// the mandatory center-square crop will show up here as a low score
/// even when the other three are confident.
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

    /// - Parameters:
    ///   - cornerHeatmap: model output "Identity", shape [1,128,128,4].
    ///     Channel order is however the model was trained (TL, TR, BR,
    ///     BL) — verified empirically against real photos rather than
    ///     assumed; see the note in CoreMLBoardDetector if this ever
    ///     needs re-checking against a fresh export.
    ///   - segmentation: model output "Identity_1", shape [1,128,128,1].
    ///   - cropRect: the actual center-square region (in the source
    ///     frame's own pixel space, y-down) that Vision cropped before
    ///     resizing to 128x128 — needed to map a heatmap pixel back to
    ///     a real frame coordinate.
    ///
    /// Always returns its best guess, even a low-confidence one — it
    /// does NOT reject low-confidence corners itself (that's
    /// `CoreMLBoardDetector.calibrate`'s call, since it also needs to
    /// decide whether to accept calibration). Returning the attempt
    /// either way lets a debug overlay show what the model is seeing
    /// even before/without a successful calibration. Only throws for
    /// genuine structural problems (wrong dtype/shape).
    static func decode(
        cornerHeatmap: MLMultiArray,
        segmentation: MLMultiArray,
        cropRect: CGRect
    ) throws -> BoardDetectionResult {
        guard cornerHeatmap.dataType == .float32, segmentation.dataType == .float32 else {
            throw BoardSegmentationError.unexpectedOutputShape
        }
        // Expect [1, H, W, 4] (channels-last, matching the TF graph).
        guard cornerHeatmap.shape.count == 4, cornerHeatmap.shape[3].intValue == 4 else {
            throw BoardSegmentationError.unexpectedOutputShape
        }
        let heatmapSize = cornerHeatmap.shape[1].intValue // 128
        let stride = cornerHeatmap.strides.map { $0.intValue }
        let ptr = cornerHeatmap.dataPointer.bindMemory(to: Float32.self, capacity: cornerHeatmap.count)

        func value(_ channel: Int, _ y: Int, _ x: Int) -> Float {
            ptr[y * stride[1] + x * stride[2] + channel * stride[3]]
        }

        // For each of the 4 channels, find the pixel with the peak
        // value — that's the model's best guess for that corner.
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
            // Map from 128x128 heatmap space -> the crop square's own
            // pixel space -> the original frame's pixel space.
            let fracX = (CGFloat(bestX) + 0.5) / CGFloat(heatmapSize)
            let fracY = (CGFloat(bestY) + 0.5) / CGFloat(heatmapSize)
            let framePoint = CGPoint(
                x: cropRect.origin.x + fracX * cropRect.width,
                y: cropRect.origin.y + fracY * cropRect.height
            )
            points.append(framePoint)
        }

        guard points.count == 4 else { throw BoardSegmentationError.decodeFailure }

        // Channel order verified against real test photos: 0=TL, 1=TR, 2=BR, 3=BL.
        let corners = BoardCorners(topLeft: points[0], topRight: points[1], bottomRight: points[2], bottomLeft: points[3])

        let segPtr = segmentation.dataPointer.bindMemory(to: Float32.self, capacity: segmentation.count)
        var segSum: Float = 0
        for i in 0..<segmentation.count { segSum += segPtr[i] }
        let segMean = segmentation.count > 0 ? segSum / Float(segmentation.count) : 0

        return BoardDetectionResult(corners: corners, cornerConfidences: confidences, segmentationConfidence: segMean)
    }
}

/// Warps a frame to a top-down view of the board using calibrated corners.
enum PerspectiveWarp {
    /// - Parameters:
    ///   - image: the full camera frame.
    ///   - corners: board corners already in `image`'s own pixel space
    ///     (origin top-left, y-down) — e.g. as produced by
    ///     `CornerHeatmapDecoder`, which does the crop-space-to-frame-
    ///     space mapping itself.
    static func warp(_ image: CIImage, corners: BoardCorners) -> CIImage? {
        // CIPerspectiveCorrection wants points in the source image's
        // own Core Image space (y-up, matches `image.extent`), so just
        // flip y — no additional scaling needed since corners are
        // already in this image's pixel space.
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
