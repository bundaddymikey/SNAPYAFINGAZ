import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var authViewModel: AuthViewModel
    @State private var catalogVM = CatalogViewModel()
    @State private var locationsVM = LocationsViewModel()
    @State private var auditVM = AuditViewModel()
    @State private var path = NavigationPath()
    @State private var showAuditFlow = false

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    welcomeHeader

                    statsRow

                    LazyVGrid(columns: columns, spacing: 12) {
                        NavigationLink(value: AppRoute.catalog) {
                            DashboardCard(
                                title: "Catalog",
                                subtitle: "\(catalogVM.products.count) products",
                                icon: "shippingbox.fill",
                                color: .blue
                            )
                        }
                        .buttonStyle(.plain)

                        NavigationLink(value: AppRoute.locations) {
                            DashboardCard(
                                title: "Locations",
                                subtitle: "\(locationsVM.locations.count) locations",
                                icon: "mappin.and.ellipse",
                                color: .green
                            )
                        }
                        .buttonStyle(.plain)

                        Button {
                            showAuditFlow = true
                        } label: {
                            DashboardCard(
                                title: "Start Audit",
                                subtitle: "Capture media",
                                icon: "camera.viewfinder",
                                color: .orange
                            )
                        }
                        .buttonStyle(.plain)

                        NavigationLink(value: AppRoute.auditHistory) {
                            DashboardCard(
                                title: "Audit History",
                                subtitle: "\(auditVM.sessions.count) sessions",
                                icon: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                                color: .indigo
                            )
                        }
                        .buttonStyle(.plain)

                        NavigationLink(value: AppRoute.lookAlikeGroups) {
                            DashboardCard(
                                title: "Look-Alikes",
                                subtitle: "Package groups",
                                icon: "square.on.square.dashed",
                                color: .cyan
                            )
                        }
                        .buttonStyle(.plain)

                        if authViewModel.isAdmin {
                            NavigationLink(value: AppRoute.users) {
                                DashboardCard(
                                    title: "Users",
                                    subtitle: "Manage team",
                                    icon: "person.2.fill",
                                    color: .purple
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    NavigationLink(value: AppRoute.settings) {
                        HStack(spacing: 12) {
                            Image(systemName: "gearshape.fill")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.secondary)
                            Text("Settings")
                                .font(.body)
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(.rect(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("SnapAudit")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        authViewModel.logout()
                    } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.body)
                    }
                }
            }
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .catalog:
                    CatalogListView(viewModel: catalogVM)
                case .locations:
                    LocationsListView(viewModel: locationsVM)
                case .users:
                    UsersListView()
                case .settings:
                    SettingsView(authViewModel: authViewModel)
                case .auditHistory:
                    AuditHistoryView(
                        auditViewModel: auditVM,
                        isAdmin: authViewModel.isAdmin,
                        navigationPath: $path
                    )
                case .sessionDetail(let session):
                    SessionDetailView(
                        session: session,
                        auditViewModel: auditVM,
                        isAdmin: authViewModel.isAdmin
                    )
                case .lookAlikeGroups:
                    LookAlikeGroupsView()
                }
            }
            .onAppear {
                catalogVM.setup(context: modelContext)
                locationsVM.setup(context: modelContext)
                auditVM.setup(context: modelContext)
            }
            .fullScreenCover(isPresented: $showAuditFlow) {
                auditVM.fetchSessions()
            } content: {
                AuditFlowView(authViewModel: authViewModel)
            }
        }
    }

    private var welcomeHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Welcome back,")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(authViewModel.currentUser?.name ?? "User")
                .font(.title.bold())
        }
        .padding(.top, 4)
    }

    private var statsRow: some View {
        HStack(spacing: 12) {
            StatPill(label: "Products", value: "\(catalogVM.products.count)", icon: "shippingbox")
            StatPill(label: "Locations", value: "\(locationsVM.locations.count)", icon: "mappin")
            StatPill(label: "Role", value: authViewModel.currentUser?.role.displayName ?? "—", icon: "person")
        }
    }
}

struct StatPill: View {
    let label: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 10))
    }
}

nonisolated enum AppRoute: Hashable {
    case catalog
    case locations
    case users
    case settings
    case auditHistory
    case sessionDetail(AuditSession)
    case lookAlikeGroups
}
