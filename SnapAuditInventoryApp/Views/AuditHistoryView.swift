import SwiftUI
import SwiftData

struct AuditHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    let auditViewModel: AuditViewModel
    let isAdmin: Bool
    @Binding var navigationPath: NavigationPath

    @State private var showDeleteAlert = false
    @State private var sessionToDelete: AuditSession?

    var body: some View {
        Group {
            if auditViewModel.sessions.isEmpty {
                emptyState
            } else {
                sessionList
            }
        }
        .navigationTitle("Audit History")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            auditViewModel.setup(context: modelContext)
        }
        .alert("Delete Session?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) {
                if let session = sessionToDelete {
                    auditViewModel.deleteSession(session)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will permanently delete the session and all captured media.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No Audits Yet")
                .font(.title3.weight(.semibold))
            Text("Start an audit from the dashboard\nto see it here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private var sessionList: some View {
        List {
            ForEach(auditViewModel.sessions) { session in
                Button {
                    navigationPath.append(AppRoute.sessionDetail(session))
                } label: {
                    sessionRow(session)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .leading) {
                    if session.status == .paused {
                        Button {
                            navigationPath.append(AppRoute.sessionDetail(session))
                        } label: {
                            Label("Resume", systemImage: "play.circle.fill")
                        }
                        .tint(.orange)
                    }
                }
                .swipeActions(edge: .trailing) {
                    if isAdmin {
                        Button(role: .destructive) {
                            sessionToDelete = session
                            showDeleteAlert = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func sessionRow(_ session: AuditSession) -> some View {
        HStack(spacing: 14) {
            Image(systemName: session.mode.icon)
                .font(.title3.weight(.medium))
                .foregroundStyle(statusColor(session.status))
                .frame(width: 40, height: 40)
                .background(statusColor(session.status).opacity(0.12))
                .clipShape(.rect(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 3) {
                Text(session.locationName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    Label(session.mode.displayName, systemImage: session.mode.icon)
                    Text("·")
                    Label(session.captureQualityMode.badgeTitle, systemImage: session.captureQualityMode.icon)
                    if !session.presetName.isEmpty {
                        Text("·")
                        Label(session.presetName, systemImage: "wand.and.stars")
                    }
                    Text("·")
                    Text("\(session.capturedMedia.count) media")
                    if !session.lineItems.isEmpty {
                        Text("·")
                        Text("\(session.totalItemCount) items")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(session.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: session.status.icon)
                        .font(.caption2)
                    Text(session.status.displayName)
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(statusColor(session.status))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(statusColor(session.status).opacity(0.1), in: Capsule())

                if session.pendingLineItemCount > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 9))
                        Text("\(session.pendingLineItemCount) pending")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.1), in: Capsule())
                }

                if session.status == .paused {
                    HStack(spacing: 3) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 9))
                        Text("Tap to Resume")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.12), in: Capsule())
                }

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private func statusColor(_ status: AuditStatus) -> Color {
        switch status {
        case .draft: .gray
        case .paused: .orange
        case .processing: .blue
        case .reviewRequired: .yellow
        case .complete: .green
        }
    }
}
