import SwiftUI

/// Lets the user choose a device role (Dashboard or Scanner) and discover/connect to peers.
struct DeviceRolePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var syncService: SessionSyncService

    @State private var selectedRole: DeviceRole?
    @State private var isConnecting = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if selectedRole == nil {
                    roleSelectionContent
                } else {
                    peerDiscoveryContent
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Multi-Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if selectedRole != nil && !syncService.multipeerService.isConnected {
                            syncService.stop()
                        }
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Role Selection

    private var roleSelectionContent: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 44))
                        .foregroundStyle(.blue)
                        .symbolEffect(.pulse, isActive: true)
                    Text("Multi-Device Audit")
                        .font(.title2.bold())
                    Text("Choose how this device will be used in the audit session.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .padding(.top, 24)

                // Role cards
                VStack(spacing: 12) {
                    ForEach(DeviceRole.allCases, id: \.self) { role in
                        Button {
                            selectedRole = role
                            syncService.start(as: role)
                        } label: {
                            roleCard(role)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)

                // Note
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                    Text("Both devices must be on the same Wi-Fi network or within Bluetooth range.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
            }
            .padding(.bottom, 32)
        }
    }

    private func roleCard(_ role: DeviceRole) -> some View {
        HStack(spacing: 16) {
            Image(systemName: role.icon)
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(role == .dashboard ? Color.blue : Color.orange, in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 4) {
                Text(role.displayName)
                    .font(.headline)
                Text(role.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Peer Discovery

    private var peerDiscoveryContent: some View {
        VStack(spacing: 0) {
            // Current role indicator
            currentRoleHeader

            if syncService.multipeerService.isConnected {
                connectedContent
            } else {
                searchingContent
            }

            Spacer()
        }
    }

    private var currentRoleHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: selectedRole?.icon ?? "questionmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(selectedRole == .dashboard ? Color.blue : Color.orange, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("This device: \(selectedRole?.displayName ?? "")")
                    .font(.subheadline.weight(.semibold))
                Text(syncService.multipeerService.connectionStatus.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Connection status dot
            Circle()
                .fill(connectionDotColor)
                .frame(width: 10, height: 10)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var searchingContent: some View {
        VStack(spacing: 20) {
            if syncService.multipeerService.discoveredPeers.isEmpty {
                // Searching animation
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Searching for nearby devices…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Make sure the other device has SnapAudit open and has selected the opposite role.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .padding(.top, 60)
            } else {
                // Discovered peers list
                VStack(alignment: .leading, spacing: 12) {
                    Text("Nearby Devices")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)

                    ForEach(syncService.multipeerService.discoveredPeers) { peer in
                        Button {
                            syncService.multipeerService.invite(peer: peer)
                        } label: {
                            peerRow(peer)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
    }

    private var connectedContent: some View {
        VStack(spacing: 24) {
            // Success state
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
                Text("Connected!")
                    .font(.title3.bold())

                if let connectedPeer = syncService.multipeerService.connectedPeers.first {
                    Text("Paired with \(connectedPeer.displayName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 40)

            // Instructions based on role
            VStack(spacing: 8) {
                if selectedRole == .scanner {
                    Label("Start a Real-Time Scan — detections will be sent to the dashboard automatically.", systemImage: "camera.viewfinder")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Label("The scanner's detections will appear here in real time.", systemImage: "rectangle.3.group")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .multilineTextAlignment(.center)

            // Disconnect button
            Button(role: .destructive) {
                syncService.stop()
                selectedRole = nil
            } label: {
                Label("Disconnect", systemImage: "wifi.slash")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 24)
        }
    }

    private func peerRow(_ peer: PeerDevice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: peer.role.icon)
                .font(.body)
                .foregroundStyle(peer.role == .dashboard ? Color.blue : Color.orange)
                .frame(width: 36, height: 36)
                .background(Color(.tertiarySystemGroupedBackground), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(peer.displayName)
                    .font(.subheadline.weight(.medium))
                Text(peer.role.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("Tap to connect")
                .font(.caption)
                .foregroundStyle(.blue)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Helpers

    private var connectionDotColor: Color {
        switch syncService.multipeerService.connectionStatus {
        case .connected: .green
        case .connecting: .orange
        case .searching: .blue
        case .disconnected: .gray
        }
    }
}
