import SwiftUI

struct DetectionBoxesOverlayView: View {
    let regions: [DetectionRegion]
    let imageSize: CGSize

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(Array(regions.enumerated()), id: \.offset) { entry in
                    let region = entry.element
                    let rect = computedRect(for: region.bbox, in: geometry.size)

                    Rectangle()
                        .strokeBorder(
                            color(for: region),
                            style: StrokeStyle(
                                lineWidth: region.isClusterSplit ? 2.5 : 1.5,
                                dash: region.isClusterSplit ? [7, 4] : []
                            )
                        )
                        .background(
                            color(for: region)
                                .opacity(region.isClusterSplit ? 0.10 : 0.05)
                        )
                        .frame(width: max(rect.width, 2), height: max(rect.height, 2))
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func computedRect(for bbox: BoundingBox, in viewSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }

        let scale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let fittedWidth = imageSize.width * scale
        let fittedHeight = imageSize.height * scale
        let offsetX = (viewSize.width - fittedWidth) / 2
        let offsetY = (viewSize.height - fittedHeight) / 2

        return CGRect(
            x: offsetX + CGFloat(bbox.x) * fittedWidth,
            y: offsetY + CGFloat(bbox.y) * fittedHeight,
            width: CGFloat(bbox.width) * fittedWidth,
            height: CGFloat(bbox.height) * fittedHeight
        )
    }

    private func color(for region: DetectionRegion) -> Color {
        switch region.scaleLevel {
        case 0.95...:
            return .blue
        case 0.70...:
            return .orange
        default:
            return .purple
        }
    }
}

struct DetectionBoxesLegendView: View {
    var body: some View {
        HStack(spacing: 8) {
            legendChip(color: .blue, label: "1.0×")
            legendChip(color: .orange, label: "0.75×")
            legendChip(color: .purple, label: "0.5×")
            splitChip
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func legendChip(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
        }
    }

    private var splitChip: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                .frame(width: 14, height: 8)
            Text("Split")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
        }
    }
}
