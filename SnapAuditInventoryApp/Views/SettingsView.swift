import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var authViewModel: AuthViewModel
    @AppStorage("isDemoMode") private var isDemoMode = false
    @AppStorage("frameSamplingRate") private var frameSamplingRate: Int = 2
    @AppStorage("saveOriginalVideo") private var saveOriginalVideo: Bool = true
    @AppStorage("reviewWorkflowDefault") private var reviewWorkflowDefault: Bool = true
    @AppStorage("autoAcceptConfidence") private var autoAcceptConfidence: Double = 0.85
    @AppStorage("reviewBandMin") private var reviewBandMin: Double = 0.60
    @AppStorage("closeMatchMargin") private var closeMatchMargin: Double = 0.10
    @AppStorage("overlayEnabledDefault") private var overlayEnabledDefault: Bool = true
    @AppStorage("overlayOpacityDefault") private var overlayOpacityDefault: Double = 0.35
    @AppStorage("overlayShowLabelsDefault") private var overlayShowLabelsDefault: Bool = true
    @AppStorage("smartFocusZonesEnabled") private var smartFocusZonesEnabled: Bool = true
    @AppStorage("smartFocusOCRZonesEnabled") private var smartFocusOCRZonesEnabled: Bool = true
    @AppStorage("showDetectionBoxes") private var showDetectionBoxes: Bool = false
    @AppStorage("defaultCaptureQualityMode") private var defaultCaptureQualityModeRaw: String = CaptureQualityMode.standard.rawValue
    @AppStorage("showAuditFramingGuide") private var showAuditFramingGuide: Bool = true
    @AppStorage("showPreCaptureWarnings") private var showPreCaptureWarnings: Bool = true
    @State private var showDemoAlert = false
    @State private var showClearAlert = false
    @State private var pendingDemoState = false

    var body: some View {
        List {
            Section("Data Mode") {
                Toggle(isOn: Binding(
                    get: { isDemoMode },
                    set: { newValue in
                        pendingDemoState = newValue
                        if newValue { showDemoAlert = true } else { showClearAlert = true }
                    }
                )) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Demo Mode")
                            Text("Load sample products, locations & users")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "flask")
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("Capture Settings") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Frame Sampling Rate", systemImage: "film.stack")
                        Spacer()
                        Text("\(frameSamplingRate) fps")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { Double(frameSamplingRate) },
                        set: { frameSamplingRate = Int($0) }
                    ), in: 1...4, step: 1)
                    Text("Higher rates produce more frames but use more storage")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Toggle(isOn: $saveOriginalVideo) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Save Original Video")
                            Text("Keep source video after frame sampling")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "video.fill")
                            .foregroundStyle(.blue)
                    }
                }
            }

            Section {
                Picker("Default Capture Quality Mode", selection: $defaultCaptureQualityModeRaw) {
                    ForEach(CaptureQualityMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }

                Toggle(isOn: $showAuditFramingGuide) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show Framing Guide")
                            Text("Display the Audit Zone rectangle and spacing hints during capture")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "viewfinder")
                            .foregroundStyle(.mint)
                    }
                }

                Toggle(isOn: $showPreCaptureWarnings) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show Pre-Capture Warnings")
                            Text("Warn about clutter, glare, contrast, and items outside the capture zone")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                    }
                }
            } header: {
                Text("Capture Quality")
            } footer: {
                Text("High Accuracy mode guides users toward plain matte backgrounds, cleaner spacing, and stronger framing before detection begins.")
                    .font(.caption2)
            }

            Section {
                Toggle(isOn: $reviewWorkflowDefault) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Default: Review Later")
                            Text("Queue all uncertain items for batch review")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "tray.full.fill")
                            .foregroundStyle(.indigo)
                    }
                }
            } header: {
                Text("Review Workflow")
            }

            if authViewModel.isAdmin {
                Section {
                    confidenceSlider(
                        title: "Auto-Accept Threshold",
                        subtitle: "Detections above this score are auto-confirmed",
                        icon: "checkmark.seal.fill",
                        color: .green,
                        value: $autoAcceptConfidence,
                        range: 0.60...0.99
                    )

                    confidenceSlider(
                        title: "Review Band Minimum",
                        subtitle: "Below this score requires manual review",
                        icon: "eye.fill",
                        color: .orange,
                        value: $reviewBandMin,
                        range: 0.30...0.80
                    )

                    confidenceSlider(
                        title: "Close Match Margin",
                        subtitle: "Minimum gap between top-1 and top-2 scores",
                        icon: "equal.circle.fill",
                        color: .purple,
                        value: $closeMatchMargin,
                        range: 0.05...0.30
                    )
                } header: {
                    Text("Recognition Thresholds (Admin)")
                } footer: {
                    Text("Auto-Accept must be higher than Review Band Minimum.")
                        .font(.caption2)
                }
            }

            Section {
                Toggle(isOn: $overlayEnabledDefault) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show Zone Overlay by Default")
                            Text("Display shelf zones on camera and image previews")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "square.grid.3x3.topleft.filled")
                            .foregroundStyle(.cyan)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Default Opacity")
                                Text("Semi-transparency of zone rectangles")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "circle.lefthalf.filled")
                                .foregroundStyle(.cyan)
                        }
                        Spacer()
                        Text("\(Int(overlayOpacityDefault * 100))%")
                            .font(.subheadline.bold().monospacedDigit())
                            .foregroundStyle(.cyan)
                            .frame(width: 42, alignment: .trailing)
                    }
                    Slider(value: $overlayOpacityDefault, in: 0.10...0.70, step: 0.05)
                        .tint(.cyan)
                        .disabled(!overlayEnabledDefault)
                        .opacity(overlayEnabledDefault ? 1 : 0.4)
                }

                Toggle(isOn: $overlayShowLabelsDefault) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show Zone Labels")
                            Text("Display zone names and assignments in overlay")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "tag.fill")
                            .foregroundStyle(.cyan)
                    }
                }
                .disabled(!overlayEnabledDefault)
                .opacity(overlayEnabledDefault ? 1 : 0.4)
            } header: {
                Text("Zone Overlay")
            } footer: {
                Text("These defaults apply when starting a new audit with a shelf layout selected. You can adjust them live in the capture screen.")
                    .font(.caption2)
            }

            Section {
                Toggle(isOn: $smartFocusZonesEnabled) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Smart Focus Zones")
                            Text("Run hotspot zoom-in recognition on informative packaging regions")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "viewfinder.circle")
                            .foregroundStyle(.purple)
                    }
                }

                Toggle(isOn: $smartFocusOCRZonesEnabled) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("OCR on Focus Zones")
                            Text("Use text recognition only on hotspot crops for keyword boosts")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "text.magnifyingglass")
                            .foregroundStyle(.purple)
                    }
                }
                .disabled(!smartFocusZonesEnabled)
                .opacity(smartFocusZonesEnabled ? 1 : 0.4)
            } header: {
                Text("Smart Recognition")
            } footer: {
                Text("Custom focus zones from Look-Alike Groups take priority. Otherwise the app uses built-in hotspot presets like top band, bottom band, side strips, and badge areas.")
                    .font(.caption2)
            }

            Section("Data Management") {
                HStack {
                    Label("Export Data", systemImage: "square.and.arrow.up")
                    Spacer()
                    Text("Coming Soon")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.tertiary)

                HStack {
                    Label("Data Retention", systemImage: "clock.arrow.circlepath")
                    Spacer()
                    Text("Coming Soon")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.tertiary)
            }

            Section("Account") {
                HStack {
                    Label("Signed in as", systemImage: "person.circle")
                    Spacer()
                    Text(authViewModel.currentUser?.name ?? "—")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Label("Role", systemImage: "shield")
                    Spacer()
                    Text(authViewModel.currentUser?.role.displayName ?? "—")
                        .foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    authViewModel.logout()
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }

            Section("Developer Tools") {
                Toggle(isOn: $showDetectionBoxes) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show Detection Boxes")
                            Text("Overlay multi-scale proposal boxes on image previews")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "viewfinder.rectangular")
                            .foregroundStyle(.orange)
                    }
                }

                NavigationLink {
                    RecognitionTestView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Test Recognition")
                            Text("Classify a photo against the catalog")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "brain.head.profile")
                            .foregroundStyle(.purple)
                    }
                }

                if authViewModel.isAdmin {
                    NavigationLink {
                        OverlayTestLabView(isAdmin: true)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Overlay Test Lab")
                                Text("Preview zone overlays on a static canvas")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "square.grid.3x3.topleft.filled")
                                .foregroundStyle(.cyan)
                        }
                    }
                }
            }

            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text("1.0.0")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Build")
                    Spacer()
                    Text("V5")
                        .foregroundStyle(.secondary)
                }
                NavigationLink {
                    PrivacyView()
                } label: {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Enable Demo Mode?", isPresented: $showDemoAlert) {
            Button("Load Demo Data") {
                DemoDataService.loadDemoData(context: modelContext)
                isDemoMode = true
                authViewModel.fetchUsers()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will add sample products, locations, and users. Your existing data will be preserved.")
        }
        .alert("Disable Demo Mode?", isPresented: $showClearAlert) {
            Button("Clear All Data", role: .destructive) {
                DemoDataService.clearAllData(context: modelContext)
                isDemoMode = false
                authViewModel.logout()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove ALL data including any custom entries you've added. You'll need to set up a new admin account.")
        }
    }

    private func confidenceSlider(
        title: String,
        subtitle: String,
        icon: String,
        color: Color,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: icon)
                        .foregroundStyle(color)
                }
                Spacer()
                Text("\(Int(value.wrappedValue * 100))%")
                    .font(.subheadline.bold().monospacedDigit())
                    .foregroundStyle(color)
                    .frame(width: 42, alignment: .trailing)
            }
            Slider(value: value, in: range, step: 0.05)
                .tint(color)
        }
    }
}

struct PrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Privacy Policy")
                    .font(.title.bold())

                Text("SnapAudit stores all data locally on your device. No data is transmitted to external servers.")
                    .font(.body)

                Text("Data Storage")
                    .font(.headline)
                Text("All inventory data, user accounts, and settings are stored exclusively on this device using Apple's SwiftData framework. PIN codes are hashed with SHA-256 and are never stored in plain text.")
                    .font(.body)

                Text("No Analytics")
                    .font(.headline)
                Text("SnapAudit does not collect any usage analytics, crash reports, or personal information.")
                    .font(.body)

                Text("Your Control")
                    .font(.headline)
                Text("You can delete all data at any time through Settings. Uninstalling the app will permanently remove all stored data.")
                    .font(.body)
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}
