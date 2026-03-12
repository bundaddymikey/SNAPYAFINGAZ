import SwiftUI

/// A small capsule badge showing confidence level at a glance.
struct ConfidenceBadge: View {
    let score: Double
    let reviewStatus: ReviewStatus

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: badgeIcon)
                .font(.caption2.weight(.bold))
            Text(badgeLabel)
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(badgeColor.opacity(0.15))
        .foregroundStyle(badgeColor)
        .clipShape(Capsule())
    }

    private var badgeLabel: String {
        switch reviewStatus {
        case .confirmed: return "Confirmed"
        case .rejected: return "Rejected"
        case .pending:
            if score >= 0.75 { return "High" }
            if score >= 0.45 { return "Review" }
            return "Low"
        }
    }

    private var badgeIcon: String {
        switch reviewStatus {
        case .confirmed: return "checkmark.circle.fill"
        case .rejected: return "xmark.circle.fill"
        case .pending:
            if score >= 0.75 { return "arrow.up.circle.fill" }
            if score >= 0.45 { return "exclamationmark.circle.fill" }
            return "arrow.down.circle.fill"
        }
    }

    private var badgeColor: Color {
        switch reviewStatus {
        case .confirmed: return .blue
        case .rejected: return .gray
        case .pending:
            if score >= 0.75 { return .green }
            if score >= 0.45 { return .orange }
            return .red
        }
    }
}
