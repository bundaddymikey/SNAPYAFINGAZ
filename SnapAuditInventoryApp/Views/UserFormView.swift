import SwiftUI

struct UserFormView: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: UsersViewModel
    let user: AppUser?

    @State private var name: String
    @State private var role: UserRole
    @State private var pin: String = ""
    @State private var confirmPin: String = ""
    @State private var errorMessage: String?

    init(viewModel: UsersViewModel, user: AppUser? = nil) {
        self.viewModel = viewModel
        self.user = user
        _name = State(initialValue: user?.name ?? "")
        _role = State(initialValue: user?.role ?? .auditor)
    }

    private var isEditing: Bool { user != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("User Info") {
                    TextField("Name", text: $name)
                        .textContentType(.name)
                    Picker("Role", selection: $role) {
                        ForEach(UserRole.allCases, id: \.self) { role in
                            Label(role.displayName, systemImage: role.icon)
                                .tag(role)
                        }
                    }
                }

                Section(header: Text(isEditing ? "Change PIN (leave blank to keep)" : "PIN"), footer: Text("PIN must be exactly 4 digits")) {
                    SecureField(isEditing ? "New PIN (optional)" : "4-Digit PIN", text: $pin)
                        .keyboardType(.numberPad)
                        .onChange(of: pin) { _, newValue in
                            pin = String(newValue.prefix(4)).filter(\.isNumber)
                        }

                    SecureField("Confirm PIN", text: $confirmPin)
                        .keyboardType(.numberPad)
                        .onChange(of: confirmPin) { _, newValue in
                            confirmPin = String(newValue.prefix(4)).filter(\.isNumber)
                        }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit User" : "New User")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            errorMessage = "Name is required"
            return
        }

        if isEditing {
            if !pin.isEmpty {
                guard pin.count == 4 else {
                    errorMessage = "PIN must be 4 digits"
                    return
                }
                guard pin == confirmPin else {
                    errorMessage = "PINs don't match"
                    return
                }
            }
            viewModel.updateUser(user!, name: trimmedName, role: role, newPin: pin.isEmpty ? nil : pin)
        } else {
            guard pin.count == 4 else {
                errorMessage = "PIN must be 4 digits"
                return
            }
            guard pin == confirmPin else {
                errorMessage = "PINs don't match"
                return
            }
            viewModel.createUser(name: trimmedName, role: role, pin: pin)
        }

        dismiss()
    }
}
