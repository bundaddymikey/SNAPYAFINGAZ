import SwiftUI

struct DashboardCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    var badge: String? = nil
    var isDisabled: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(color)
                    .frame(width: 44, height: 44)
                    .background(color.opacity(0.12))
                    .clipShape(.rect(cornerRadius: 10))

                Spacer()

                if let badge {
                    Text(badge)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(color.opacity(isDisabled ? 0.4 : 1.0))
                        .clipShape(Capsule())
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(isDisabled ? .tertiary : .primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
        .opacity(isDisabled ? 0.6 : 1.0)
    }
}
