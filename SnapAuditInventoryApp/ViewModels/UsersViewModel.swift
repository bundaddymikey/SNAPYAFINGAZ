import SwiftUI
import SwiftData

@Observable
@MainActor
class UsersViewModel {
    var users: [AppUser] = []

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

    func createUser(name: String, role: UserRole, pin: String) {
        guard let modelContext else { return }
        let salt = PINService.generateSalt()
        let hash = PINService.hash(pin: pin, salt: salt)
        let user = AppUser(name: name, role: role, pinHash: hash, pinSalt: salt)
        modelContext.insert(user)
        try? modelContext.save()
        fetchUsers()
    }

    func updateUser(_ user: AppUser, name: String, role: UserRole, newPin: String?) {
        user.name = name
        user.role = role
        if let newPin, !newPin.isEmpty {
            let salt = PINService.generateSalt()
            user.pinSalt = salt
            user.pinHash = PINService.hash(pin: newPin, salt: salt)
        }
        try? modelContext?.save()
        fetchUsers()
    }

    func deleteUser(_ user: AppUser) {
        guard let modelContext else { return }
        modelContext.delete(user)
        try? modelContext.save()
        fetchUsers()
    }
}
