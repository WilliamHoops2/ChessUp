//
//  DebugOverlayView.swift
//  ChessUp
//
//  Created by William Silvano Angga on 15/09/26.
//

import SwiftUI

struct DebugOverlayView: View {
    let corners: BoardCorners?
    let cornerConfidences: [Float]?
    let imageSize: CGSize
    let statusMessage: String
    let isCalibrated: Bool
    let warpedImage: CGImage?
    let detectedPieces: [PieceDetectionDebug]
    let boardGrid: BoardGrid
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

    private func warpedThumbnail(_ image: CGImage, in geo: GeometryProxy) -> some View {
        let side: CGFloat = 140
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

                Path { path in
                    for x in xPositions.dropFirst().dropLast() {
                        path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: side))
                    }
                    for y in yPositions.dropFirst().dropLast() {
                        path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: side, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.5), lineWidth: 0.75)

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

    private func mapPoint(_ point: CGPoint, imageSize: CGSize, viewSize: CGSize) -> CGPoint {
        let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale
        let offsetX = (viewSize.width - scaledWidth) / 2
        let offsetY = (viewSize.height - scaledHeight) / 2
        return CGPoint(x: offsetX + point.x * scale, y: offsetY + point.y * scale)
    }
}
