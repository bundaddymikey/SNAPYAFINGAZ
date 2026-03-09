import SwiftUI

private let overlayZoneColors: [Color] = [
    .blue, .orange, .green, .purple, .pink, .teal, .indigo, .cyan
]

struct ZoneOverlayView: View {
    let zones: [ShelfZone]
    var showLabels: Bool = true
    var opacity: Double = 0.35
    var imageSize: CGSize? = nil
    var onTapZone: ((ShelfZone) -> Void)? = nil

    @State private var highlightedZoneId: UUID? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(Array(zones.enumerated()), id: \.element.id) { idx, zone in
                    let rect = computedRect(for: zone, in: geo.size)
                    let color = overlayZoneColors[idx % overlayZoneColors.count]
                    let isHighlighted = highlightedZoneId == zone.id

                    zoneCell(zone: zone, color: color, isHighlighted: isHighlighted)
                        .frame(width: max(rect.width, 2), height: max(rect.height, 2))
                        .position(x: rect.midX, y: rect.midY)
                        .onTapGesture {
                            guard let onTapZone else { return }
                            withAnimation(.spring(response: 0.25)) {
                                highlightedZoneId = zone.id
                            }
                            Task {
                                try? await Task.sleep(for: .milliseconds(700))
                                withAnimation(.easeOut(duration: 0.3)) {
                                    highlightedZoneId = nil
                                }
                            }
                            onTapZone(zone)
                        }
                }
            }
        }
        .allowsHitTesting(onTapZone != nil)
    }

    @ViewBuilder
    private func zoneCell(zone: ShelfZone, color: Color, isHighlighted: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(color.opacity(isHighlighted ? 0.55 : opacity * 0.65))
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(color, lineWidth: isHighlighted ? 3 : 1.5)
            if showLabels {
                VStack(alignment: .leading, spacing: 1) {
                    Text(zone.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.8), radius: 1)
                    if zone.isAssigned {
                        Text(zone.assignmentLabel)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.9))
                            .shadow(color: .black.opacity(0.8), radius: 1)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
            }
        }
    }

    private func computedRect(for zone: ShelfZone, in viewSize: CGSize) -> CGRect {
        let r = zone.rect
        if let img = imageSize, img.width > 0, img.height > 0 {
            let scale = min(viewSize.width / img.width, viewSize.height / img.height)
            let fw = img.width * scale
            let fh = img.height * scale
            let ox = (viewSize.width - fw) / 2
            let oy = (viewSize.height - fh) / 2
            return CGRect(
                x: ox + r.x * fw,
                y: oy + r.y * fh,
                width: r.w * fw,
                height: r.h * fh
            )
        }
        return CGRect(
            x: r.x * viewSize.width,
            y: r.y * viewSize.height,
            width: r.w * viewSize.width,
            height: r.h * viewSize.height
        )
    }
}
