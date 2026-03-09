import SwiftUI

struct SafeModeView: View {
    @State private var showTestLab = false
    @State private var showResetConfirm = false

    private var lastError: String {
        UserDefaults.standard.string(forKey: "LastStartupError") ?? "Unknown startup error."
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    safeModeHeader

                    errorCard

                    actionButtons

                    Spacer(minLength: 32)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Safe Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Safe Mode")
                            .fontWeight(.semibold)
                    }
                }
            }
        }
        .sheet(isPresented: $showTestLab) {
            OverlayTestLabView(isAdmin: true)
        }
        .alert("Reset All Local Data?", isPresented: $showResetConfirm) {
            Button("Reset & Restart", role: .destructive) {
                SafeModeActions.resetLocalData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes all SwiftData stores and cached media, then restarts the app. This cannot be undone.")
        }
    }

    private var safeModeHeader: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 88, height: 88)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
            }

            Text("App Launched in Safe Mode")
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text("The app encountered an error during startup and fell back to a temporary in-memory state. Your persisted data is not affected.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 12)
    }

    private var errorCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "ladybug.fill")
                    .foregroundStyle(.red)
                Text("Startup Error")
                    .font(.subheadline.bold())
            }

            Text(lastError)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(.tertiarySystemBackground))
                .clipShape(.rect(cornerRadius: 8))
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .clipShape(.rect(cornerRadius: 14))
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            safeModeButton(
                title: "Retry Normal Launch",
                subtitle: "Restart the app and attempt normal boot",
                icon: "arrow.clockwise",
                color: .blue
            ) {
                UserDefaults.standard.set(false, forKey: "LastLaunchFailed")
                UserDefaults.standard.removeObject(forKey: "LastStartupError")
                exit(0)
            }

            safeModeButton(
                title: "Reset Local Data",
                subtitle: "Delete all stores and cached media, then restart",
                icon: "trash.fill",
                color: .red
            ) {
                showResetConfirm = true
            }

            safeModeButton(
                title: "Open Overlay Test Lab",
                subtitle: "Preview zone overlays on a static canvas",
                icon: "square.grid.3x3.topleft.filled",
                color: .cyan
            ) {
                showTestLab = true
            }
        }
    }

    private func safeModeButton(
        title: String,
        subtitle: String,
        icon: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(color.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(color)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(.secondarySystemBackground))
            .clipShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

enum SafeModeActions {
    static func resetLocalData() {
        let fm = FileManager.default

        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let mediaDir = docs.appendingPathComponent("SnapAuditMedia")
        try? fm.removeItem(at: mediaDir)

        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if let contents = try? fm.contentsOfDirectory(at: appSupport, includingPropertiesForKeys: nil) {
            for url in contents {
                let name = url.lastPathComponent
                if name.hasSuffix(".store")
                    || name.hasSuffix(".store-wal")
                    || name.hasSuffix(".store-shm")
                    || name.hasSuffix(".sqlite")
                    || name.hasSuffix(".sqlite-wal")
                    || name.hasSuffix(".sqlite-shm") {
                    try? fm.removeItem(at: url)
                }
            }
        }

        UserDefaults.standard.set(false, forKey: "LastLaunchFailed")
        UserDefaults.standard.removeObject(forKey: "LastStartupError")
        UserDefaults.standard.set(false, forKey: "isDemoMode")

        exit(0)
    }
}
