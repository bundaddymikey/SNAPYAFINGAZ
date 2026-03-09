import SwiftUI
import SwiftData

@Observable
@MainActor
class AuthViewModel {
    var currentUser: AppUser?
    var isAuthenticated = false
    var users: [AppUser] = []
    var pinEntry = ""
    var selectedUser: AppUser?
    var loginError: String?
    var isShaking = false

    private var modelContext: ModelContext?

    func setup(context: ModelContext) {
        self.modelContext = context
        fetchUsers()
    }

    func fetchUsers() {
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<AppUser>(sortBy: [SortDescriptor(\.name)])
        users = (try? modelContext.fetch(descriptor)) ?? []
    }

    func attemptLogin() {
        guard let selectedUser, let modelContext else { return }
        if PINService.verify(pin: pinEntry, hash: selectedUser.pinHash, salt: selectedUser.pinSalt) {
            currentUser = selectedUser
            isAuthenticated = true
            loginError = nil
            pinEntry = ""
        } else {
            loginError = "Incorrect PIN"
            isShaking = true
            pinEntry = ""
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                isShaking = false
            }
        }
    }

    func logout() {
        currentUser = nil
        isAuthenticated = false
        selectedUser = nil
        pinEntry = ""
        loginError = nil
    }

    var isAdmin: Bool {
        currentUser?.role == .admin
    }

    var hasUsers: Bool {
        !users.isEmpty
    }

    func createInitialAdmin(name: String, pin: String, context: ModelContext) {
        let salt = PINService.generateSalt()
        let hash = PINService.hash(pin: pin, salt: salt)
        let admin = AppUser(name: name, role: .admin, pinHash: hash, pinSalt: salt)
        context.insert(admin)
        try? context.save()
        self.modelContext = context
        fetchUsers()
    }
}
