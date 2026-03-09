import SwiftUI
import SwiftData

struct LoginView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var authViewModel: AuthViewModel
    @State private var showSetup = false

    var body: some View {
        Group {
            if !authViewModel.hasUsers {
                InitialSetupView(authViewModel: authViewModel)
            } else if authViewModel.selectedUser == nil {
                UserSelectionView(authViewModel: authViewModel)
            } else {
                PINEntryView(authViewModel: authViewModel)
            }
        }
        .onAppear {
            authViewModel.setup(context: modelContext)
        }
    }
}

struct InitialSetupView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var authViewModel: AuthViewModel
    @State private var adminName = ""
    @State private var pin = ""
    @State private var confirmPin = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.pulse, options: .repeating)

                Text("Welcome to SnapAudit")
                    .font(.title.bold())

                Text("Set up your admin account to get started")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 40)

            VStack(spacing: 16) {
                TextField("Admin Name", text: $adminName)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.name)
                    .autocorrectionDisabled()

                SecureField("4-Digit PIN", text: $pin)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .onChange(of: pin) { _, newValue in
                        pin = String(newValue.prefix(4)).filter(\.isNumber)
                    }

                SecureField("Confirm PIN", text: $confirmPin)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .onChange(of: confirmPin) { _, newValue in
                        confirmPin = String(newValue.prefix(4)).filter(\.isNumber)
                    }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 32)

            Spacer()

            PrimaryButton("Create Admin Account", icon: "person.badge.shield.checkmark") {
                guard !adminName.trimmingCharacters(in: .whitespaces).isEmpty else {
                    errorMessage = "Please enter a name"
                    return
                }
                guard pin.count == 4 else {
                    errorMessage = "PIN must be 4 digits"
                    return
                }
                guard pin == confirmPin else {
                    errorMessage = "PINs don't match"
                    return
                }
                authViewModel.createInitialAdmin(name: adminName, pin: pin, context: modelContext)
                errorMessage = nil
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
    }
}

struct UserSelectionView: View {
    @Bindable var authViewModel: AuthViewModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Select User")
                    .font(.title2.bold())
                Text("Choose your account to sign in")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 32)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(authViewModel.users, id: \.id) { user in
                        Button {
                            authViewModel.selectedUser = user
                            authViewModel.loginError = nil
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: user.role.icon)
                                    .font(.title3)
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 44, height: 44)
                                    .background(Color.accentColor.opacity(0.1))
                                    .clipShape(Circle())

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(user.name)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text(user.role.displayName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(14)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(.rect(cornerRadius: 12))
                        }
                    }
                }
                .padding(.horizontal, 24)
            }

            Spacer()
        }
        .background(Color(.systemGroupedBackground))
    }
}

struct PINEntryView: View {
    @Bindable var authViewModel: AuthViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    authViewModel.selectedUser = nil
                    authViewModel.pinEntry = ""
                    authViewModel.loginError = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Spacer()

            VStack(spacing: 8) {
                if let user = authViewModel.selectedUser {
                    Image(systemName: user.role.icon)
                        .font(.system(size: 36))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 72, height: 72)
                        .background(Color.accentColor.opacity(0.1))
                        .clipShape(Circle())

                    Text(user.name)
                        .font(.title3.bold())

                    Text("Enter your PIN")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 32)

            PINKeypadView(pin: $authViewModel.pinEntry, maxDigits: 4) {
                authViewModel.attemptLogin()
            }
            .offset(x: authViewModel.isShaking ? -10 : 0)
            .animation(.default.repeatCount(3, autoreverses: true).speed(6), value: authViewModel.isShaking)

            if let error = authViewModel.loginError {
                Text(error)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.red)
                    .padding(.top, 16)
            }

            Spacer()
        }
        .background(Color(.systemGroupedBackground))
        .sensoryFeedback(.error, trigger: authViewModel.loginError)
    }
}
