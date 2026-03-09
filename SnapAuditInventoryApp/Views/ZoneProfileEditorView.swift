import SwiftUI

private let zoneColors: [Color] = [.blue, .orange, .green, .purple]

struct ZoneProfileEditorView: View {
    @Binding var zones: [ZoneRect]
    @State private var selectedIndex: Int? = nil

    var body: some View {
        VStack(spacing: 0) {
            presetBar
                .padding(.bottom, 12)

            ZoneCanvas(zones: $zones, selectedIndex: $selectedIndex)
                .aspectRatio(0.55, contentMode: .fit)
                .padding(.horizontal, 16)

            if zones.isEmpty {
                emptyZoneState
            } else {
                zoneControls
            }
        }
    }

    private var presetBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ZonePreset.allCases, id: \.self) { preset in
                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            zones = preset.zones
                            selectedIndex = zones.isEmpty ? nil : 0
                        }
                    } label: {
                        Label(preset.rawValue, systemImage: preset.icon)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color(.tertiarySystemFill))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var emptyZoneState: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.dashed")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Select a preset or add a zone")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                withAnimation(.spring(response: 0.3)) {
                    zones.append(ZoneRect(name: "Zone \(zones.count + 1)", x: 0.1, y: 0.1, w: 0.8, h: 0.35, weight: 2.0))
                    selectedIndex = zones.count - 1
                }
            } label: {
                Label("Add Zone", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.blue)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var zoneControls: some View {
        VStack(spacing: 0) {
            Divider()
                .padding(.top, 12)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(zones.enumerated()), id: \.element.id) { idx, zone in
                        ZoneSliderRow(
                            zone: Binding(
                                get: { zones[idx] },
                                set: { zones[idx] = $0 }
                            ),
                            color: zoneColors[idx % zoneColors.count],
                            isSelected: selectedIndex == idx
                        ) {
                            withAnimation { selectedIndex = idx }
                        } onDelete: {
                            withAnimation(.spring(response: 0.3)) {
                                zones.remove(at: idx)
                                if selectedIndex == idx {
                                    selectedIndex = zones.isEmpty ? nil : max(0, idx - 1)
                                }
                            }
                        }
                    }

                    if zones.count < 4 {
                        Button {
                            withAnimation(.spring(response: 0.3)) {
                                zones.append(ZoneRect(
                                    name: "Zone \(zones.count + 1)",
                                    x: 0.05, y: Double(zones.count) * 0.2,
                                    w: 0.9, h: 0.18,
                                    weight: 2.0
                                ))
                                selectedIndex = zones.count - 1
                            }
                        } label: {
                            Label("Add Zone", systemImage: "plus.circle")
                                .font(.subheadline)
                                .foregroundStyle(.blue)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color(.tertiarySystemFill))
                                .clipShape(.rect(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
        }
    }
}

struct ZoneCanvas: View {
    @Binding var zones: [ZoneRect]
    @Binding var selectedIndex: Int?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .shadow(color: .black.opacity(0.06), radius: 4, y: 2)

                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(.separator).opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5]))
                    .padding(16)

                Image(systemName: "shippingbox")
                    .font(.system(size: 40))
                    .foregroundStyle(Color(.separator).opacity(0.25))

                ForEach(Array(zones.enumerated()), id: \.element.id) { idx, zone in
                    ZoneRectView(
                        zone: Binding(get: { zones[idx] }, set: { zones[idx] = $0 }),
                        color: zoneColors[idx % zoneColors.count],
                        isSelected: selectedIndex == idx,
                        canvasSize: geo.size
                    ) {
                        selectedIndex = selectedIndex == idx ? nil : idx
                    }
                }
            }
        }
    }
}

struct ZoneRectView: View {
    @Binding var zone: ZoneRect
    let color: Color
    let isSelected: Bool
    let canvasSize: CGSize
    let onTap: () -> Void

    @GestureState private var dragOffset: CGSize = .zero

    private var canvasW: Double { Double(canvasSize.width) }
    private var canvasH: Double { Double(canvasSize.height) }

    var body: some View {
        let x = (zone.x + dragOffset.width / canvasW) * canvasW
        let y = (zone.y + dragOffset.height / canvasH) * canvasH
        let rw = zone.w * canvasW
        let rh = zone.h * canvasH

        RoundedRectangle(cornerRadius: 4)
            .fill(color.opacity(0.20))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(color, lineWidth: isSelected ? 2 : 1.5)
            }
            .overlay(alignment: .topLeading) {
                Text(zone.name)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.15))
                    .clipShape(Capsule())
                    .padding(4)
            }
            .frame(width: rw, height: rh)
            .position(x: x + rw / 2, y: y + rh / 2)
            .gesture(
                DragGesture()
                    .updating($dragOffset) { value, state, _ in
                        state = value.translation
                    }
                    .onEnded { value in
                        let dx = value.translation.width / canvasW
                        let dy = value.translation.height / canvasH
                        zone.x = max(0, min(1.0 - zone.w, zone.x + dx))
                        zone.y = max(0, min(1.0 - zone.h, zone.y + dy))
                    }
            )
            .onTapGesture { onTap() }
            .animation(.spring(response: 0.25), value: isSelected)
    }
}

struct ZoneSliderRow: View {
    @Binding var zone: ZoneRect
    let color: Color
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            Button(action: { withAnimation(.spring(response: 0.25)) { isExpanded.toggle(); onSelect() } }) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color.opacity(0.25))
                        .frame(width: 28, height: 28)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(color, lineWidth: 1.5)
                        }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(zone.name)
                            .font(.subheadline.weight(.medium))
                        Text("Weight ×\(String(format: "%.1f", zone.weight))  ·  W:\(Int(zone.w * 100))% H:\(Int(zone.h * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)

                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(isSelected ? color.opacity(0.06) : Color(.tertiarySystemFill))
                .clipShape(.rect(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 10) {
                    TextField("Zone name", text: $zone.name)
                        .textFieldStyle(.roundedBorder)
                        .font(.subheadline)

                    ZoneSlider(label: "Weight", value: $zone.weight, range: 1.0...4.0, color: color, format: "%.1f×")
                    ZoneSlider(label: "Width", value: $zone.w, range: 0.1...1.0, color: color, format: "%d%%") { Int($0 * 100) }
                    ZoneSlider(label: "Height", value: $zone.h, range: 0.05...1.0, color: color, format: "%d%%") { Int($0 * 100) }
                    ZoneSlider(label: "Left", value: $zone.x, range: 0...0.9, color: color, format: "%d%%") { Int($0 * 100) }
                    ZoneSlider(label: "Top", value: $zone.y, range: 0...0.9, color: color, format: "%d%%") { Int($0 * 100) }
                }
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 10))
                .padding(.top, 4)
            }
        }
    }
}

struct ZoneSlider<F>: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let color: Color
    let format: String
    let formatter: (Double) -> F

    init(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        color: Color,
        format: String,
        formatter: @escaping (Double) -> F = { $0 }
    ) {
        self.label = label
        self._value = value
        self.range = range
        self.color = color
        self.format = format
        self.formatter = formatter
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Slider(value: $value, in: range)
                .tint(color)
            Text(displayValue)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    private var displayValue: String {
        if F.self == Int.self {
            return String(format: format, formatter(value) as! Int)
        } else if F.self == Double.self {
            return String(format: format, formatter(value) as! Double)
        }
        return String(format: "%.2f", value)
    }
}
