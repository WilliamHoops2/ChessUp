//
//  DebugOverlayView.swift
//  ChessUp
//
//  Created by William Silvano Angga on 15/09/26.
//
//  Draws whatever the vision pipeline currently sees on top of the
//  camera preview: the 4 corner points (color-coded, with their
//  confidence scores), lines connecting them into the quadrilateral
//  the perspective warp will use, and a status banner mirroring the
//  console log. Exists purely for debugging/testing — has zero effect
//  on detection itself, which reads directly from CoreMLBoardDetector
//  independently of anything drawn here.
//
//  Corner colors: red = top-left, green = top-right, blue =
//  bottom-right, yellow = bottom-left — matching that order makes it
//  easy to spot an unexpected rotation (e.g. if what looks like the
//  board's actual top-left corner gets marked blue instead of red,
//  that's a real orientation mismatch worth investigating, not just a
//  low-confidence miss).
//

import SwiftUI

struct DebugOverlayView: View {
    let corners: BoardCorners?
    let cornerConfidences: [Float]?
    /// Pixel size of the raw camera frame the corners were computed
    /// in — needed to map frame-space points onto this view's own
    /// size, accounting for the preview's aspect-fill cropping.
    let imageSize: CGSize
    let statusMessage: String
    let isCalibrated: Bool
    /// The warped top-down crop pieces-model actually analyzed this
    /// frame, and whatever it found there. Shown as a small inset
    /// thumbnail so "is grid/piece detection working" has a direct
    /// visual answer instead of having to infer it from corner
    /// coordinates or console text alone.
    let warpedImage: CGImage?
    let detectedPieces: [PieceDetectionDebug]
    let boardGrid: BoardGrid
    /// Real device safe-area insets, captured by GameView from a
    /// GeometryReader that sits ABOVE any `.ignoresSafeArea()` call.
    /// This view itself is full-bleed (ignoring safe area, so corner
    /// markers line up with the full-bleed camera preview), which
    /// means a GeometryReader placed inside it would report ~0 for
    /// these — SwiftUI zeroes out `safeAreaInsets` for any edge a view
    /// has already opted out of. Passing the real values in from
    /// outside that boundary is what actually clears the Dynamic
    /// Island/notch and home indicator.
    let safeAreaTop: CGFloat
    let safeAreaBottom: CGFloat

    private let cornerColors: [Color] = [.red, .green, .blue, .yellow]
    private let cornerLabels = ["TL", "TR", "BR", "BL"]

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                if let corners, imageSize.width > 0, imageSize.height > 0 {
                    let points = [corners.topLeft, corners.topRight, corners.bottomRight, corners.bottomLeft]
                        .map { mapPoint($0, imageSize: imageSize, viewSize: geo.size) }

                    // Quadrilateral outline connecting the 4 corners.
                    Path { path in
                        guard let first = points.first else { return }
                        path.move(to: first)
                        for p in points.dropFirst() { path.addLine(to: p) }
                        path.closeSubpath()
                    }
                    .stroke(isCalibrated ? Color.green : Color.orange, lineWidth: 2)

                    // One marker per corner, color-coded and labeled
                    // with its confidence so a weak/clipped corner is
                    // obvious at a glance.
                    ForEach(0..<points.count, id: \.self) { i in
                        VStack(spacing: 2) {
                            Text(cornerLabels[i] + (cornerConfidences.map { i < $0.count ? String(format: " %.2f", $0[i]) : "" } ?? ""))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(cornerColors[i].opacity(0.85))
                                .cornerRadius(4)
                            Circle()
                                .fill(cornerColors[i])
                                .frame(width: 10, height: 10)
                        }
                        .position(points[i])
                    }
                }

                // Status banner mirroring the console log, so you can
                // see what's happening without a cable attached. Uses
                // `safeAreaTop` (passed in from GameView, captured
                // above the ignoresSafeArea boundary) rather than this
                // view's own GeometryReader — see the `safeAreaTop`
                // doc comment for why that's necessary here.
                Text(statusMessage.isEmpty ? "Waiting for first frame…" : statusMessage)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(8)
                    .padding(.top, safeAreaTop + 12)
                    .frame(maxWidth: .infinity)

                if let warpedImage {
                    warpedThumbnail(warpedImage, in: geo)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Small inset showing the exact crop pieces-model saw this frame,
    /// with an 8x8 grid (the same grid `CoreMLBoardDetector.detectPieces`
    /// buckets box-centers into) and a box per detection. Bottom-right,
    /// clear of the home indicator via `safeAreaBottom` (see that
    /// property's doc comment for why this can't use its own
    /// GeometryReader's safeAreaInsets instead).
    private func warpedThumbnail(_ image: CGImage, in geo: GeometryProxy) -> some View {
        let side: CGFloat = 140
        // Vision convention (origin bottom-left, y-up) -> this
        // thumbnail's own top-left/y-down drawing space.
        let xPositions = boardGrid.fileLines.map { $0 * side }
        let yPositions = boardGrid.rankLines.map { (1 - $0) * side }
        return VStack(spacing: 0) {
            Text(detectedPieces.isEmpty ? "pieces: none" : "pieces: \(detectedPieces.count)")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.85))

            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
                    .clipped()

                // The ACTUAL refined grid lines detectPieces() buckets
                // box-centers into (GridRefiner.swift) — not a uniform
                // /8 split, so this should visibly hug the real board
                // edges even when the perspective warp isn't pixel-perfect.
                Path { path in
                    for x in xPositions.dropFirst().dropLast() {
                        path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: side))
                    }
                    for y in yPositions.dropFirst().dropLast() {
                        path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: side, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.5), lineWidth: 0.75)

                // One box per detected piece. Vision boxes are
                // normalized with origin bottom-left; this thumbnail's
                // coordinate space is top-left, so flip y.
                ForEach(Array(detectedPieces.enumerated()), id: \.offset) { _, piece in
                    let rect = CGRect(
                        x: piece.boundingBox.minX * side,
                        y: (1 - piece.boundingBox.maxY) * side,
                        width: piece.boundingBox.width * side,
                        height: piece.boundingBox.height * side
                    )
                    Rectangle()
                        .stroke(Color.cyan, lineWidth: 1.5)
                        .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                        .position(x: rect.midX, y: rect.midY)
                }
            }
            .frame(width: side, height: side)
            .background(Color.black)
        }
        .overlay(Rectangle().stroke(Color.white.opacity(0.6), lineWidth: 1))
        .position(
            x: geo.size.width - side / 2 - 12,
            y: geo.size.height - side / 2 - safeAreaBottom - 12
        )
    }

    /// Maps a point in the source frame's own pixel space to this
    /// view's coordinate space, replicating the same math
    /// AVCaptureVideoPreviewLayer's `.resizeAspectFill` gravity uses
    /// (CameraPreviewView sets that same gravity) — so a corner drawn
    /// here should land exactly on the corner the model actually found
    /// in the live feed, not some offset/scaled version of it.
    private func mapPoint(_ point: CGPoint, imageSize: CGSize, viewSize: CGSize) -> CGPoint {
        let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale
        let offsetX = (viewSize.width - scaledWidth) / 2
        let offsetY = (viewSize.height - scaledHeight) / 2
        return CGPoint(x: offsetX + point.x * scale, y: offsetY + point.y * scale)
    }
}
