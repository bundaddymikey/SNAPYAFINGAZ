import SwiftUI
import SwiftData

struct UsersListView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = UsersViewModel()
    @State private var showAddUser = false
    @State private var userToEdit: AppUser?
    @State private var showDeleteAlert = false
    @State private var userToDelete: AppUser?

    var body: some View {
        List {
            ForEach(viewModel.users, id: \.id) { user in
                UserRow(user: user)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            userToDelete = user
                            showDeleteAlert = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            userToEdit = user
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.orange)
                    }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if viewModel.users.isEmpty {
                EmptyStateView(
                    title: "No Users",
                    subtitle: "Tap + to create a new user",
                    icon: "person.2"
                )
            }
        }
        .navigationTitle("Users")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddUser = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddUser) {
            UserFormView(viewModel: viewModel)
        }
        .sheet(item: $userToEdit) { user in
            UserFormView(viewModel: viewModel, user: user)
        }
        .alert("Delete User?", isPresented: $showDeleteAlert, presenting: userToDelete) { user in
            Button("Delete", role: .destructive) { viewModel.deleteUser(user) }
            Button("Cancel", role: .cancel) { }
        } message: { user in
            Text("This will permanently delete \"\(user.name)\".")
        }
        .onAppear { viewModel.setup(context: modelContext) }
    }
}

struct UserRow: View {
    let user: AppUser

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: user.role.icon)
                .font(.body.weight(.medium))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(roleColor)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(user.name)
                    .font(.body.weight(.medium))
                Text(user.role.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(user.createdAt.formatted(date: .abbreviated, time: .omitted))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private var roleColor: Color {
        switch user.role {
        case .admin: .purple
        case .auditor: .blue
        case .viewer: .gray
        }
    }
}
