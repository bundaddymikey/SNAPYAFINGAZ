import SwiftUI

/// Modal sheet for discovering and connecting to nearby Inateck scanners.
/// Presented from SettingsView when "Scan for Scanners" is tapped.
struct ScannerDiscoverySheet: View {
    @Environment(\.dismiss) private var dismiss
    let connectionService: ScannerConnectionService

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                VStack(spacing: 0) {
                    if connectionService.discoveredDevices.isEmpty {
                        emptyState
                    } else {
                        deviceList
                    }
                }
            }
            .navigationTitle("Available Scanners")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        connectionService.stopDiscovery()
                        dismiss()
                    }
                }
            }
            .onAppear {
                connectionService.startDiscovery()
            }
            .onDisappear {
                if case .scanning = connectionService.state {
                    connectionService.stopDiscovery()
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            if case .scanning = connectionService.state {
                ProgressView()
                    .controlSize(.large)
                    .padding(.bottom, 8)
                Text("Scanning for nearby scanners…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Make sure your scanner is powered on\nand in pairing mode.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            } else if case .error(let msg) = connectionService.state {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.red)
                Text(msg)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button("Try Again") {
                    connectionService.startDiscovery()
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var deviceList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(connectionService.discoveredDevices) { device in
                    deviceRow(device)
                    Divider().padding(.leading, 56)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
    }

    private func deviceRow(_ device: ScannerConnectionService.DiscoveredDevice) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "barcode.viewfinder")
                .font(.title2)
                .foregroundStyle(.cyan)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.body.weight(.medium))
                Text(device.id.prefix(8) + "…")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            connectButton(for: device)
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func connectButton(for device: ScannerConnectionService.DiscoveredDevice) -> some View {
        if case .connecting(let name) = connectionService.state, name == device.name {
            ProgressView()
                .controlSize(.small)
        } else if case .connected(_, let name) = connectionService.state, name == device.name {
            Label("Connected", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        } else {
            Button {
                connectionService.connect(device: device)
            } label: {
                Text("Connect")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.cyan, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}
