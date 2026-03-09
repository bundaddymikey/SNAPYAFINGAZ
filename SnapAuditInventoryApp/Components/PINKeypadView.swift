import SwiftUI

struct PINKeypadView: View {
    @Binding var pin: String
    let maxDigits: Int
    var onComplete: (() -> Void)?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: 3)

    private let keys: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["", "0", "delete"]
    ]

    var body: some View {
        VStack(spacing: 24) {
            HStack(spacing: 14) {
                ForEach(0..<maxDigits, id: \.self) { index in
                    Circle()
                        .fill(index < pin.count ? Color.accentColor : Color(.tertiarySystemFill))
                        .frame(width: 16, height: 16)
                        .scaleEffect(index < pin.count ? 1.0 : 0.85)
                        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: pin.count)
                }
            }
            .padding(.bottom, 8)

            VStack(spacing: 12) {
                ForEach(keys, id: \.self) { row in
                    HStack(spacing: 16) {
                        ForEach(row, id: \.self) { key in
                            if key.isEmpty {
                                Color.clear
                                    .frame(width: 75, height: 75)
                            } else if key == "delete" {
                                Button {
                                    guard !pin.isEmpty else { return }
                                    pin.removeLast()
                                } label: {
                                    Image(systemName: "delete.backward")
                                        .font(.title2)
                                        .foregroundStyle(.primary)
                                        .frame(width: 75, height: 75)
                                }
                                .disabled(pin.isEmpty)
                            } else {
                                Button {
                                    guard pin.count < maxDigits else { return }
                                    pin += key
                                    if pin.count == maxDigits {
                                        onComplete?()
                                    }
                                } label: {
                                    Text(key)
                                        .font(.title.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .frame(width: 75, height: 75)
                                        .background(Color(.secondarySystemBackground))
                                        .clipShape(Circle())
                                }
                                .sensoryFeedback(.impact(weight: .light), trigger: pin.count)
                            }
                        }
                    }
                }
            }
        }
    }
}
