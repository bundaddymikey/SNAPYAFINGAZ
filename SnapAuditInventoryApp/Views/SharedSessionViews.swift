import SwiftUI

// MARK: - HostSessionView

/// Shown on the dashboard when hosting a shared session.
/// Displays the 6-character session code and a QR code for the scanner to scan.
struct HostSessionView: View {
    let syncService: SessionSyncService
    let auditSession: AuditSession
    @Environment(\.dismiss) private var dismiss

    @State private var sessionCode: String = ""
    @State private var qrImage: UIImage?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {

                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 40))
                            .foregroundStyle(.blue)
                        Text("Multi-Device Session")
                            .font(.title2.bold())
                        Text("Have the scanner device enter this code or scan the QR.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    .padding(.top, 16)

                    // Session code
                    VStack(spacing: 8) {
                        Text("Session Code")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(formattedCode)
                            .font(.system(size: 44, weight: .bold, design: .monospaced))
                            .kerning(8)
                            .foregroundStyle(.primary)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 24)

                    // QR code
                    if let qr = qrImage {
                        VStack(spacing: 8) {
                            Text("Or scan this QR code")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Image(uiImage: qr)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 200, height: 200)
                                .padding(12)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }

                    // Connection status
                    connectionStatusSection

                    // Session info
                    VStack(alignment: .leading, spacing: 8) {
                        Label(auditSession.locationName, systemImage: "mappin")
                        Label("Session ID: " + auditSession.id.uuidString.prefix(8), systemImage: "doc.text")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Host Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                activate()
            }
        }
    }

    // MARK: - Private

    private var formattedCode: String {
        // Insert a space in the middle for readability: "ABC DEF"
        guard sessionCode.count == 6 else { return sessionCode }
        let mid = sessionCode.index(sessionCode.startIndex, offsetBy: 3)
        return String(sessionCode[..<mid]) + " " + String(sessionCode[mid...])
    }

    private var connectionStatusSection: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(syncService.multipeerService.isConnected ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
            Text(syncService.multipeerService.isConnected
                 ? "Scanner connected — \(syncService.activeSharedSession?.participantSummary ?? "")"
                 : syncService.multipeerService.connectionStatus.rawValue)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
    }

    private func activate() {
        // Start hosting (advertising) if not already
        if !syncService.multipeerService.isAdvertising {
            syncService.start(as: .dashboard)
        }
        // Create the shared session and generate the code
        sessionCode = syncService.hostSession(auditSession: auditSession)
        qrImage = SessionCodeService.qrCode(for: sessionCode, size: 200)
    }
}

// MARK: - JoinSessionView

/// Shown on the scanner device to join an existing session by code or QR.
struct JoinSessionView: View {
    let syncService: SessionSyncService
    @Environment(\.dismiss) private var dismiss

    @State private var enteredCode: String = ""
    @State private var isShowingScanner = false
    @FocusState private var isCodeFieldFocused: Bool

    private var normalizedCode: String {
        enteredCode.uppercased().filter { $0.isLetter || $0.isNumber }
    }
    private var isCodeReady: Bool { normalizedCode.count == 6 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {

                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 40))
                            .foregroundStyle(.orange)
                        Text("Join a Session")
                            .font(.title2.bold())
                        Text("Enter the 6-character code shown on the dashboard device.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    .padding(.top, 16)

                    // Code entry
                    VStack(spacing: 12) {
                        TextField("e.g. ABC DEF", text: $enteredCode)
                            .font(.system(size: 32, weight: .bold, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)
                            .focused($isCodeFieldFocused)
                            .onChange(of: enteredCode) { _, new in
                                // Enforce 6-char max (stripped)
                                let stripped = new.uppercased().filter { $0.isLetter || $0.isNumber }
                                if stripped.count > 6 {
                                    enteredCode = String(stripped.prefix(6))
                                }
                            }

                        Divider()
                    }
                    .padding(.horizontal, 40)

                    // Join button
                    Button {
                        syncService.requestJoin(code: normalizedCode)
                    } label: {
                        Text("Join Session")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isCodeReady || syncService.joinState == .waitingForAck)
                    .padding(.horizontal, 24)

                    // Status feedback
                    joinStatusView

                    // Connection requirement note
                    if !syncService.multipeerService.isConnected {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Pair with the dashboard device first using the Multi-Device tab.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 24)
                    }
                }
                .padding(.bottom, 40)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Join Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                isCodeFieldFocused = true
                // Start browsing if not already
                if !syncService.multipeerService.isBrowsing {
                    syncService.start(as: .scanner)
                }
            }
            .onChange(of: syncService.joinState) { _, newState in
                if case .joined = newState { dismiss() }
            }
        }
    }

    // MARK: - Join Status

    @ViewBuilder
    private var joinStatusView: some View {
        switch syncService.joinState {
        case .idle:
            EmptyView()

        case .waitingForAck:
            HStack(spacing: 8) {
                ProgressView()
                Text("Waiting for dashboard to respond…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

        case .joined:
            Label("Joined! Starting scan mode…", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.subheadline)

        case .rejected(let reason):
            VStack(spacing: 4) {
                Label("Join rejected", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

// MARK: - Shared Session Banner (inline component for DashboardView)

/// A compact banner displayed at the top of DashboardView when a shared session is active.
struct SharedSessionBannerView: View {
    let syncService: SessionSyncService

    var body: some View {
        guard let session = syncService.activeSharedSession else { return AnyView(EmptyView()) }
        return AnyView(
            HStack(spacing: 10) {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Shared Session Active")
                        .font(.caption.weight(.semibold))
                    Text("\(session.participantSummary) · Code: \(session.sessionCode)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(syncService.scanEventStore.totalCount) scans")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.blue)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        )
    }
}
