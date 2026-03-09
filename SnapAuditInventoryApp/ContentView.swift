import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var authViewModel = AuthViewModel()

    var body: some View {
        Group {
            if authViewModel.isAuthenticated {
                DashboardView(authViewModel: authViewModel)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                LoginView(authViewModel: authViewModel)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: authViewModel.isAuthenticated)
    }
}
