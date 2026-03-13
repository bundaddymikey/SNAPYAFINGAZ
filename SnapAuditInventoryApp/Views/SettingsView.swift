import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ScannerConnectionService.self) private var scannerConnection
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
    @AppStorage("contrastiveVariantTrainingEnabled") private var contrastiveVariantTrainingEnabled: Bool = true
    @AppStorage("ocrAssistedVariantComparison") private var ocrAssistedVariantComparison: Bool = true
    @AppStorage("adaptiveFocusZoneWeighting") private var adaptiveFocusZoneWeighting: Bool = true
    @AppStorage("ttsReadbackEnabled") private var ttsReadbackEnabled: Bool = true
    @AppStorage("ttsSpeechRate") private var ttsSpeechRate: Double = 0.48
    @AppStorage("barcodeAutoSpeak") private var barcodeAutoSpeak: Bool = true
    @AppStorage("defaultRecognitionScope") private var defaultRecognitionScopeRaw: String = RecognitionScope.all.rawValue
    @AppStorage("defaultStrictBrandFilter") private var defaultStrictBrandFilter: Bool = true
    @AppStorage("defaultAllowPossibleStragglers") private var defaultAllowPossibleStragglers: Bool = false
    @AppStorage("hardwareScannerEnabled") private var hardwareScannerEnabled: Bool = true
    @State private var showDemoAlert = false
    @State private var showClearAlert = false
    @State private var pendingDemoState = false
    @State private var showDiscoverySheet = false
    @State private var showSampleDataAlert = false
    @State private var sampleDataMessage = ""

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
                Picker("Default Scope", selection: $defaultRecognitionScopeRaw) {
                    ForEach(RecognitionScope.allCases, id: \.self) { scope in
                        Label(scope.displayName, systemImage: scope.icon).tag(scope.rawValue)
                    }
                }

                Toggle(isOn: $defaultStrictBrandFilter) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Default: Strict Brand Filter")
                            Text("Candidates outside selected brands are fully excluded")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "building.2.fill")
                            .foregroundStyle(.purple)
                    }
                }

                Toggle(isOn: $defaultAllowPossibleStragglers) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Default: Allow Possible Stragglers")
                            Text("Outside-brand items may surface if confidence is very high")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "building.2.slash.fill")
                            .foregroundStyle(.teal)
                    }
                }
                .disabled(defaultStrictBrandFilter)
            } header: {
                Text("Recognition Scope")
            } footer: {
                Text("Controls the default brand-limiting behavior for new audits. Override per-session in New Audit Setup.")
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

                Toggle(isOn: $contrastiveVariantTrainingEnabled) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Contrastive Variant Training")
                            Text("Compare similar variants within Look-Alike Groups to reduce false positives")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundStyle(.orange)
                    }
                }

                Toggle(isOn: $ocrAssistedVariantComparison) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("OCR Assisted Variant Comparison")
                            Text("Use OCR text matching during contrastive comparison")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "doc.text.magnifyingglass")
                            .foregroundStyle(.orange)
                    }
                }
                .disabled(!contrastiveVariantTrainingEnabled)
                .opacity(contrastiveVariantTrainingEnabled ? 1 : 0.4)

                Toggle(isOn: $adaptiveFocusZoneWeighting) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Adaptive Focus Zone Weighting")
                            Text("Auto-adjust zone weights based on confirmed matches")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "slider.horizontal.below.square.and.square.filled")
                            .foregroundStyle(.orange)
                    }
                }
                .disabled(!contrastiveVariantTrainingEnabled)
                .opacity(contrastiveVariantTrainingEnabled ? 1 : 0.4)
            } header: {
                Text("Smart Recognition")
            } footer: {
                Text("Custom focus zones from Look-Alike Groups take priority. Contrastive Variant Training adds an additional comparison pass for near-identical packaging variants.")
                    .font(.caption2)
            }

            Section {
                Toggle(isOn: $ttsReadbackEnabled) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("TTS Readback")
                            Text("Read product names and counts aloud")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "speaker.wave.2.fill")
                            .foregroundStyle(.blue)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Speech Rate", systemImage: "gauge.with.needle")
                            .font(.subheadline)
                        Spacer()
                        Text(speechRateLabel)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $ttsSpeechRate, in: 0.30...0.60, step: 0.02)
                        .tint(.blue)
                }
                .disabled(!ttsReadbackEnabled)
                .opacity(ttsReadbackEnabled ? 1 : 0.4)

                Toggle(isOn: $barcodeAutoSpeak) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Barcode Auto-Speak")
                            Text("Announce product name when barcode is scanned")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "barcode.viewfinder")
                            .foregroundStyle(.cyan)
                    }
                }
                .disabled(!ttsReadbackEnabled)
                .opacity(ttsReadbackEnabled ? 1 : 0.4)
            } header: {
                Text("Audio & Accessibility")
            } footer: {
                Text("Double-tap any line item in results to hear it read aloud. Use the speaker button to read all items.")
                    .font(.caption2)
            }

            Section {
                Toggle(isOn: $hardwareScannerEnabled) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hardware Scanner")
                            Text("Accept barcode input from Bluetooth HID scanners (e.g. Inateck BCST-70)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "barcode.viewfinder")
                            .foregroundStyle(.cyan)
                    }
                }
            } header: {
                Text("Hardware Scanner")
            } footer: {
                Text("Pair your scanner in iOS Settings → Bluetooth. The scanner sends barcodes as keyboard input — no SDK required.")
                    .font(.caption2)
            }

            Section {
                // Connection status
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Status")
                            Text(scannerConnection.state.displayName)
                                .font(.caption)
                                .foregroundStyle(scannerConnection.state.isConnected ? .green : .secondary)
                        }
                    } icon: {
                        Image(systemName: scannerConnection.state.icon)
                            .foregroundStyle(scannerConnection.state.isConnected ? .green : .secondary)
                    }
                }

                // Battery (only when connected)
                if scannerConnection.state.isConnected {
                    HStack {
                        Label("Battery", systemImage: "battery.75percent")
                        Spacer()
                        if let battery = scannerConnection.batteryLevel {
                            Text("\(battery)%")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.green)
                        } else {
                            Text("—")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Scan for Scanners button
                if !scannerConnection.state.isConnected {
                    Button {
                        showDiscoverySheet = true
                    } label: {
                        Label("Scan for Scanners", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }

                // Disconnect button
                if scannerConnection.state.isConnected {
                    Button(role: .destructive) {
                        scannerConnection.disconnect()
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                    }

                    // Test Beep
                    Button {
                        scannerConnection.beep()
                    } label: {
                        Label("Test Beep", systemImage: "speaker.wave.2")
                    }
                }
            } header: {
                Text("Scanner Connection (SDK)")
            } footer: {
                Text("Connect directly to the BCST-70 via Inateck SDK for battery monitoring, beeper control, and advanced features.")
                    .font(.caption2)
            }
            .sheet(isPresented: $showDiscoverySheet) {
                ScannerDiscoverySheet(connectionService: scannerConnection)
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

                Button {
                    let count = SampleDataService.loadSampleProducts(context: modelContext)
                    if count > 0 {
                        sampleDataMessage = "Loaded \(count) sample products"
                        showSampleDataAlert = true
                    } else {
                        sampleDataMessage = "Sample products already loaded"
                        showSampleDataAlert = true
                    }
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Load Sample Products")
                            Text("Add 10 test products for recognition testing")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "tray.and.arrow.down.fill")
                            .foregroundStyle(.green)
                    }
                }

                Button(role: .destructive) {
                    SampleDataService.removeSampleProducts(context: modelContext)
                    sampleDataMessage = "Sample products removed"
                    showSampleDataAlert = true
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Remove Sample Products")
                            Text("Delete all products tagged 'sample'")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "tray.and.arrow.up.fill")
                            .foregroundStyle(.red)
                    }
                }

                NavigationLink {
                    DebugLogView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Debug Log")
                            Text("View recognition events and review decisions")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "ant.fill")
                            .foregroundStyle(.gray)
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
        .alert("Sample Data", isPresented: $showSampleDataAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sampleDataMessage)
        }
    }

    private var speechRateLabel: String {
        switch ttsSpeechRate {
        case ..<0.36: "Slow"
        case 0.36..<0.46: "Normal"
        case 0.46..<0.54: "Medium"
        default: "Fast"
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
