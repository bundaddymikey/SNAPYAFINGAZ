import SwiftUI

struct EmptyStateView: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(subtitle)
        }
    }
}
