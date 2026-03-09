import SwiftUI
import SwiftData
import AVFoundation

struct CaptureView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let session: AuditSession
    let auditViewModel: AuditViewModel
    let isAdmin: Bool
    let onCaptureComplete: () -> Void

    @State private var captureService = CaptureService()
    @State private var showFinishAlert = false
    @State private var permissionDenied = false
    @State private var selectedImages: [UIImage] = []
    @State private var showLibraryPicker = false

    @AppStorage("overlayEnabledDefault") private var overlayEnabledDefault: Bool = true
    @AppStorage("overlayOpacityDefault") private var overlayOpacityDefault: Double = 0.35
    @AppStorage("overlayShowLabelsDefault") private var overlayShowLabelsDefault: Bool = true
    @AppStorage("showDetectionBoxes") private var showDetectionBoxes: Bool = false
    @AppStorage("showAuditFramingGuide") private var showAuditFramingGuide: Bool = true
    @AppStorage("showPreCaptureWarnings") private var showPreCaptureWarnings: Bool = true

    @State private var currentLayout: ShelfLayout? = nil
    @State private var overlayEnabled: Bool = true
    @State private var overlayOpacity: Double = 0.35
    @State private var overlayShowLabels: Bool = true
    @State private var showOverlayControls: Bool = false
    @State private var selectedZoneForEdit: ShelfZone? = nil
    @State private var previewImage: UIImage? = nil
    @State private var showImagePreview: Bool = false
    @State private var captureQualityAssessment: CaptureQualityAssessment = .empty

    @Query private var allSKUs: [ProductSKU]
    @Query private var allGroups: [LookAlikeGroup]

    private var maxPhotos: Int { session.mode == .hybrid ? 1 : 8 }
    private var canTakeMore: Bool { captureService.capturedPhotos.count < maxPhotos }
    private var minVideoSeconds: Double { 5 }
    private var maxVideoSeconds: Double { 20 }

    private var useLibraryMode: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return AVCaptureDevice.default(for: .video) == nil
        #endif
    }

    private var hasMedia: Bool {
        useLibraryMode
            ? !selectedImages.isEmpty
            : (!captureService.capturedPhotos.isEmpty || captureService.recordedVideoURL != nil)
    }

    private var currentZones: [ShelfZone] {
        currentLayout?.sortedZones ?? []
    }

    private var isHighAccuracyMode: Bool {
        session.captureQualityMode == .highAccuracy
    }

    private var latestPreviewImage: UIImage? {
        if useLibraryMode {
            return selectedImages.last
        }
        if let data = captureService.capturedPhotos.last {
            return UIImage(data: data)
        }
        return captureService.lastCapturedImage
    }

    private var activeWarnings: [CaptureQualityWarning] {
        guard isHighAccuracyMode, showPreCaptureWarnings else { return [] }
        return captureQualityAssessment.warnings
    }

    private var hasOutOfBoundsZones: Bool {
        currentZones.contains { z in
            let r = z.rect
            return (r.x + r.w) > 1.05 || (r.y + r.h) > 1.05
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if useLibraryMode {
                libraryModeView
            } else {
                VStack(spacing: 0) {
                    cameraPreview
                    captureControls
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showFinishAlert = true } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if hasMedia {
                    Button("Done") { finishCapture() }
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.blue, in: Capsule())
                }
            }
        }
        .alert("Discard Session?", isPresented: $showFinishAlert) {
            Button("Discard", role: .destructive) {
                if !useLibraryMode { captureService.tearDown() }
                dismiss()
            }
            Button("Keep Editing", role: .cancel) { }
        }
        .alert("Camera Access Required", isPresented: $permissionDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) { dismiss() }
        } message: {
            Text("SnapAudit needs camera access to capture audit media. Please enable it in Settings.")
        }
        .sheet(isPresented: $showLibraryPicker) {
            PhotoLibraryPicker(
                onSelect: { images in
                    let remaining = maxPhotos - selectedImages.count
                    let toAdd = Array(images.prefix(max(0, remaining)))
                    selectedImages.append(contentsOf: toAdd)
                },
                maxItems: max(1, maxPhotos - selectedImages.count)
            )
        }
        .sheet(isPresented: $showImagePreview) {
            if let img = previewImage {
                ImageOverlayPreviewSheet(
                    image: img,
                    zones: currentZones,
                    showLabels: overlayShowLabels,
                    opacity: overlayOpacity,
                    showDetectionBoxes: showDetectionBoxes,
                    isAdmin: isAdmin,
                    allSKUs: allSKUs,
                    allGroups: allGroups,
                    onSave: { try? modelContext.save() }
                )
            }
        }
        .sheet(item: $selectedZoneForEdit) { zone in
            ZoneQuickEditSheet(
                zone: zone,
                allSKUs: allSKUs,
                allGroups: allGroups,
                onSave: { try? modelContext.save() }
            )
        }
        .task {
            overlayEnabled = overlayEnabledDefault
            overlayOpacity = overlayOpacityDefault
            overlayShowLabels = overlayShowLabelsDefault
            guard !useLibraryMode else { return }
            let granted = await captureService.requestPermissions()
            if !granted {
                permissionDenied = true
                return
            }
            captureService.setupSession()
        }
        .task(id: session.selectedLayoutId) {
            guard let layoutId = session.selectedLayoutId else {
                currentLayout = nil
                return
            }
            let descriptor = FetchDescriptor<ShelfLayout>(
                predicate: #Predicate { $0.id == layoutId }
            )
            currentLayout = (try? modelContext.fetch(descriptor))?.first
        }
        .onChange(of: selectedImages.count) { _, _ in
            updateCaptureQualityAssessment()
        }
        .onChange(of: captureService.capturedPhotos.count) { _, _ in
            updateCaptureQualityAssessment()
        }
        .onAppear {
            captureQualityAssessment = session.captureQualityAssessment
        }
        .onDisappear {
            if !useLibraryMode { captureService.tearDown() }
        }
    }

    // MARK: - Library Mode

    private var libraryModeView: some View {
        VStack(spacing: 0) {
            if let layout = currentLayout {
                layoutActiveBanner(layout: layout)
            }

            if isHighAccuracyMode {
                captureQualityModeBanner
            }

            if !activeWarnings.isEmpty {
                warningBannerStack
            }

            if selectedImages.isEmpty {
                emptyLibraryState
            } else {
                selectedPhotosGrid
            }

            libraryControls
        }
    }

    private func layoutActiveBanner(layout: ShelfLayout) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.3x3.topleft.filled")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.cyan)
            Text(layout.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
            Text("· \(layout.zones.count) zones")
                .font(.caption)
                .foregroundStyle(.gray)
            Spacer()
            if !selectedImages.isEmpty {
                Label("Tap to preview", systemImage: "hand.tap")
                    .font(.caption2)
                    .foregroundStyle(.gray)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.cyan.opacity(0.08))
    }

    private var emptyLibraryState: some View {
        ScrollView {
            VStack(spacing: 20) {
                if isHighAccuracyMode {
                    preCaptureGuidanceCard
                        .padding(.horizontal, 20)
                        .padding(.top, 24)
                }

                VStack(spacing: 20) {
                    Image(systemName: "photo.stack.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.gray)

                    VStack(spacing: 6) {
                        Text("Add Photos to Audit")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                        Text("Select from your library or use demo images\nto test the audit pipeline.")
                            .font(.subheadline)
                            .foregroundStyle(.gray)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 260)
            }
        }
        .background(Color(.systemGray6).opacity(0.08))
    }

    private var selectedPhotosGrid: some View {
        ScrollView {
            let cols = [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)]
            LazyVGrid(columns: cols, spacing: 4) {
                ForEach(selectedImages.indices, id: \.self) { idx in
                    Color.black
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            Image(uiImage: selectedImages[idx])
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .allowsHitTesting(false)
                        }
                        .clipShape(.rect(cornerRadius: 6))
                        .overlay {
                            if isHighAccuracyMode && showAuditFramingGuide {
                                AuditZoneGuideView(showSpacingHints: true)
                                    .padding(8)
                                    .allowsHitTesting(false)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            Button {
                                selectedImages.remove(at: idx)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.white)
                                    .shadow(radius: 2)
                            }
                            .padding(4)
                        }
                        .overlay(alignment: .bottomLeading) {
                            if currentLayout != nil {
                                Image(systemName: "square.grid.3x3.topleft.filled")
                                    .font(.caption2)
                                    .foregroundStyle(.cyan)
                                    .padding(4)
                                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                                    .padding(5)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard currentLayout != nil else { return }
                            previewImage = selectedImages[idx]
                            showImagePreview = true
                        }
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
    }

    private var libraryControls: some View {
        VStack(spacing: 12) {
            if !selectedImages.isEmpty {
                HStack {
                    Image(systemName: "photo.stack")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(selectedImages.count)/\(maxPhotos) photos selected")
                        .font(.caption)
                        .foregroundStyle(.gray)
                    Spacer()
                    if isHighAccuracyMode {
                        captureScoreChip
                    }
                }
            }

            HStack(spacing: 12) {
                Button {
                    showLibraryPicker = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.body.weight(.medium))
                        Text(selectedImages.isEmpty ? "Select from Library" : "Add More")
                            .font(.body.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color(.systemGray5))
                    .foregroundStyle(.white)
                    .clipShape(.rect(cornerRadius: 12))
                }
                .disabled(selectedImages.count >= maxPhotos)
                .opacity(selectedImages.count >= maxPhotos ? 0.4 : 1)

                if selectedImages.isEmpty {
                    Button {
                        addDemoImages()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                                .font(.body.weight(.medium))
                            Text("Demo Images")
                                .font(.body.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.indigo.opacity(0.8))
                        .foregroundStyle(.white)
                        .clipShape(.rect(cornerRadius: 12))
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 20)
        .background(.black.opacity(0.85))
    }

    // MARK: - Camera Mode

    private var cameraPreview: some View {
        GeometryReader { geo in
            ZStack {
                if captureService.isSessionRunning {
                    Color.black
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.gray)
                        Text("Initializing camera…")
                            .font(.subheadline)
                            .foregroundStyle(.gray)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if overlayEnabled && !currentZones.isEmpty {
                    ZoneOverlayView(
                        zones: currentZones,
                        showLabels: overlayShowLabels,
                        opacity: overlayOpacity,
                        onTapZone: isAdmin ? { zone in
                            selectedZoneForEdit = zone
                        } : nil
                    )
                }

                if isHighAccuracyMode && showAuditFramingGuide {
                    AuditZoneGuideView(showSpacingHints: true)
                        .padding(24)
                        .allowsHitTesting(false)
                }

                VStack {
                    HStack(alignment: .top) {
                        if currentLayout != nil {
                            overlayControlPill
                        }
                        Spacer()
                        statusBadges
                    }
                    .padding()

                    if showOverlayControls && currentLayout != nil {
                        overlayControlPanel
                            .padding(.horizontal, 16)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if !activeWarnings.isEmpty {
                        warningBannerStack
                            .padding(.horizontal, 16)
                    }

                    Spacer()

                    if overlayEnabled && hasOutOfBoundsZones {
                        alignmentHintBanner
                            .padding(.bottom, 8)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if session.mode == .video || (session.mode == .hybrid && captureService.capturedPhotos.count >= 1) {
                        if captureService.isRecording {
                            guidanceText
                        }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Overlay Controls

    private var overlayControlPill: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                showOverlayControls.toggle()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: overlayEnabled
                    ? "square.grid.3x3.topleft.filled"
                    : "square.grid.3x3")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(overlayEnabled ? .cyan : .gray)
                Text(overlayEnabled ? "Zones" : "Zones Off")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                Image(systemName: showOverlayControls ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.gray)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private var overlayControlPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let layout = currentLayout {
                    Label(layout.name, systemImage: "square.grid.3x3.topleft.filled")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.cyan)
                }
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.3)) {
                        showOverlayControls = false
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
            }

            HStack(spacing: 10) {
                Toggle(isOn: $overlayEnabled) {
                    Label("Show", systemImage: overlayEnabled ? "eye.fill" : "eye.slash")
                        .font(.caption.weight(.medium))
                }
                .toggleStyle(.button)
                .tint(.cyan)
                .controlSize(.mini)

                Divider()
                    .frame(height: 20)
                    .overlay(.white.opacity(0.2))

                Toggle(isOn: $overlayShowLabels) {
                    Label("Labels", systemImage: "tag.fill")
                        .font(.caption.weight(.medium))
                }
                .toggleStyle(.button)
                .tint(.cyan)
                .controlSize(.mini)
                .disabled(!overlayEnabled)
                .opacity(overlayEnabled ? 1 : 0.4)
            }

            if overlayEnabled {
                HStack(spacing: 8) {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.caption2)
                        .foregroundStyle(.gray)
                    Slider(value: $overlayOpacity, in: 0.10...0.70, step: 0.05)
                        .tint(.cyan)
                    Text("\(Int(overlayOpacity * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.gray)
                        .frame(width: 30, alignment: .trailing)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var alignmentHintBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.yellow)
            Text("Move camera to fit the full layout.")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.72), in: Capsule())
    }

    // MARK: - Status Badges

    private var statusBadges: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if session.mode == .photo || session.mode == .hybrid {
                HStack(spacing: 4) {
                    Image(systemName: "camera.fill")
                        .font(.caption2)
                    Text("\(captureService.capturedPhotos.count)/\(maxPhotos)")
                        .font(.caption.monospacedDigit())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.black.opacity(0.5), in: Capsule())
            }

            if isHighAccuracyMode {
                Label(session.captureQualityMode.badgeTitle, systemImage: session.captureQualityMode.icon)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.mint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.5), in: Capsule())
            }

            if captureService.isRecording {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text(formatDuration(captureService.recordingDuration))
                        .font(.caption.monospacedDigit())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.black.opacity(0.5), in: Capsule())
            }

            if captureService.isLowLight {
                Label("Low Light", systemImage: "sun.min")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.5), in: Capsule())
            }
        }
    }

    private var guidanceText: some View {
        Text(session.captureQualityMode == .highAccuracy ? "Keep products inside the audit zone and move slowly" : "Move slowly left to right")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.black.opacity(0.5), in: Capsule())
            .padding(.bottom, 8)
    }

    @ViewBuilder
    private var captureControls: some View {
        VStack(spacing: 16) {
            switch session.mode {
            case .photo:
                photoControls
            case .video:
                videoControls
            case .hybrid:
                hybridControls
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(.black.opacity(0.85))
    }

    private var photoControls: some View {
        VStack(spacing: 12) {
            if canTakeMore {
                Text("Tap to capture • \(maxPhotos - captureService.capturedPhotos.count) remaining")
                    .font(.caption)
                    .foregroundStyle(.gray)
            } else {
                Text("Maximum photos reached")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            shutterButton(isVideo: false, disabled: !canTakeMore) {
                captureService.takePhoto { _ in }
            }
        }
    }

    private var videoControls: some View {
        VStack(spacing: 12) {
            if captureService.isRecording {
                let remaining = maxVideoSeconds - captureService.recordingDuration
                Text(remaining > 0 ? "\(Int(remaining))s remaining" : "Maximum reached")
                    .font(.caption)
                    .foregroundStyle(remaining < 3 ? .orange : .gray)
            } else if captureService.recordedVideoURL != nil {
                Text("Video recorded ✓")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Text("Hold to record • 5–20 seconds")
                    .font(.caption)
                    .foregroundStyle(.gray)
            }

            shutterButton(
                isVideo: true,
                disabled: captureService.recordedVideoURL != nil && !captureService.isRecording
            ) {
                if captureService.isRecording {
                    if captureService.recordingDuration >= minVideoSeconds {
                        captureService.stopRecording()
                    }
                } else {
                    captureService.startRecording()
                }
            }
        }
        .onChange(of: captureService.recordingDuration) { _, newValue in
            if newValue >= maxVideoSeconds && captureService.isRecording {
                captureService.stopRecording()
            }
        }
    }

    private var hybridControls: some View {
        VStack(spacing: 12) {
            if captureService.capturedPhotos.isEmpty {
                Text("Take 1 photo first")
                    .font(.caption)
                    .foregroundStyle(.gray)

                shutterButton(isVideo: false, disabled: false) {
                    captureService.takePhoto { _ in }
                }
            } else if captureService.recordedVideoURL == nil {
                Text("Optional: record a short clip")
                    .font(.caption)
                    .foregroundStyle(.gray)

                HStack(spacing: 32) {
                    shutterButton(isVideo: true, disabled: false) {
                        if captureService.isRecording {
                            if captureService.recordingDuration >= minVideoSeconds {
                                captureService.stopRecording()
                            }
                        } else {
                            captureService.startRecording()
                        }
                    }
                }
                .onChange(of: captureService.recordingDuration) { _, newValue in
                    if newValue >= maxVideoSeconds && captureService.isRecording {
                        captureService.stopRecording()
                    }
                }
            } else {
                Text("Capture complete")
                    .font(.caption)
                    .foregroundStyle(.green)

                shutterButton(isVideo: false, disabled: true) { }
            }
        }
    }

    private func shutterButton(isVideo: Bool, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 4)
                    .frame(width: 72, height: 72)

                if isVideo {
                    if captureService.isRecording {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.red)
                            .frame(width: 28, height: 28)
                    } else {
                        Circle()
                            .fill(.red)
                            .frame(width: 56, height: 56)
                    }
                } else {
                    Circle()
                        .fill(.white)
                        .frame(width: 56, height: 56)
                }
            }
        }
        .disabled(disabled)
        .opacity(disabled ? 0.3 : 1)
        .sensoryFeedback(.impact(weight: .medium), trigger: captureService.capturedPhotos.count)
    }

    // MARK: - Actions

    private func finishCapture() {
        auditViewModel.setup(context: modelContext)
        let imagesForAssessment: [UIImage] = useLibraryMode
            ? selectedImages
            : captureService.capturedPhotos.compactMap { UIImage(data: $0) }
        let assessment = CaptureQualityService.shared.aggregate(images: imagesForAssessment)
        captureQualityAssessment = assessment
        session.captureQualityMetadataJSON = CaptureQualityService.shared.encode(assessment)

        if useLibraryMode {
            for image in selectedImages {
                if let data = image.jpegData(compressionQuality: 0.85) {
                    auditViewModel.addPhoto(data: data, to: session)
                }
            }
        } else {
            for photoData in captureService.capturedPhotos {
                auditViewModel.addPhoto(data: photoData, to: session)
            }
            if let videoURL = captureService.recordedVideoURL {
                auditViewModel.addVideo(tempURL: videoURL, to: session)
            }
            captureService.tearDown()
        }

        try? modelContext.save()
        onCaptureComplete()
    }

    private func addDemoImages() {
        let demoItems: [(name: String, color: UIColor)] = [
            ("Item A",  .systemBlue),
            ("Item B",  .systemRed),
            ("Item C",  .systemGreen),
            ("Item D",  .systemOrange),
            ("Item E",  .systemPurple),
            ("Item F",  .systemTeal)
        ]
        let count = min(maxPhotos, demoItems.count)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 480, height: 360))

        for i in 0..<count {
            let item = demoItems[i]
            let img = renderer.image { ctx in
                item.color.withAlphaComponent(0.75).setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 480, height: 360))

                let titleAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 36, weight: .bold),
                    .foregroundColor: UIColor.white
                ]
                let title = "Demo \(item.name)" as NSString
                let sz = title.size(withAttributes: titleAttrs)
                title.draw(
                    at: CGPoint(x: (480 - sz.width) / 2, y: (360 - sz.height) / 2 - 20),
                    withAttributes: titleAttrs
                )

                let subAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 18, weight: .regular),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.8)
                ]
                let sub = "Inventory Item" as NSString
                let subSz = sub.size(withAttributes: subAttrs)
                sub.draw(
                    at: CGPoint(x: (480 - subSz.width) / 2, y: (360 - sz.height) / 2 + 26),
                    withAttributes: subAttrs
                )
            }
            selectedImages.append(img)
        }
    }

    private var captureQualityModeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: session.captureQualityMode.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.mint)
            Text(session.captureQualityMode.badgeTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
            Spacer()
            if captureQualityAssessment.score > 0 {
                captureScoreChip
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.mint.opacity(0.12))
    }

    private var warningBannerStack: some View {
        VStack(spacing: 8) {
            ForEach(activeWarnings) { warning in
                HStack(spacing: 8) {
                    Image(systemName: warning.icon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.yellow)
                    Text(warning.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.72), in: Capsule())
            }
        }
    }

    private var preCaptureGuidanceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "viewfinder")
                    .font(.headline)
                    .foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("High Accuracy Guidance")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Set up a clean capture surface before taking photos.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(CaptureGuidanceTip.highAccuracyTips) { tip in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: tip.icon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.mint)
                        .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tip.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text(tip.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground).opacity(0.22))
        .clipShape(.rect(cornerRadius: 16))
    }

    private var captureScoreChip: some View {
        Text("\(Int(captureQualityAssessment.score * 100))%")
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.mint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.mint.opacity(0.16), in: Capsule())
    }

    private func updateCaptureQualityAssessment() {
        guard isHighAccuracyMode else {
            captureQualityAssessment = .empty
            return
        }
        guard let image = latestPreviewImage else {
            captureQualityAssessment = .empty
            return
        }
        captureQualityAssessment = CaptureQualityService.shared.analyze(image: image)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

private struct AuditZoneGuideView: View {
    let showSpacingHints: Bool

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width * 0.68
            let height = geometry.size.height * 0.68

            VStack {
                Spacer()
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(.mint.opacity(0.95), style: StrokeStyle(lineWidth: 2, dash: [10, 6]))
                    .frame(width: width, height: height)
                    .overlay {
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                            .padding(10)
                    }
                    .overlay(alignment: .topLeading) {
                        Text("AUDIT ZONE")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.7), in: Capsule())
                            .padding(12)
                    }
                    .overlay {
                        if showSpacingHints {
                            VStack(spacing: 0) {
                                Spacer()
                                HStack(spacing: 0) {
                                    Spacer()
                                    spacingHintLine
                                    Spacer()
                                    spacingHintLine
                                    Spacer()
                                }
                                Spacer()
                                HStack(spacing: 0) {
                                    Spacer()
                                    spacingHintLine
                                    Spacer()
                                    spacingHintLine
                                    Spacer()
                                }
                                Spacer()
                            }
                            .padding(28)
                        }
                    }
                Spacer()
            }
        }
        .accessibilityHidden(true)
    }

    private var spacingHintLine: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(.white.opacity(0.22))
            .frame(width: 1.5, height: 28)
    }
}

// MARK: - Image Overlay Preview Sheet

private struct ImageOverlayPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let image: UIImage
    let zones: [ShelfZone]
    var showLabels: Bool
    var opacity: Double
    let showDetectionBoxes: Bool
    let isAdmin: Bool
    let allSKUs: [ProductSKU]
    let allGroups: [LookAlikeGroup]
    let onSave: () -> Void

    @State private var selectedZone: ShelfZone? = nil
    @State private var detectionRegions: [DetectionRegion] = []
    @State private var isLoadingDetectionBoxes: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                GeometryReader { _ in
                    ZStack {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .allowsHitTesting(false)

                        if !zones.isEmpty {
                            ZoneOverlayView(
                                zones: zones,
                                showLabels: showLabels,
                                opacity: opacity,
                                imageSize: image.size,
                                onTapZone: isAdmin ? { zone in
                                    selectedZone = zone
                                } : nil
                            )
                        }

                        if showDetectionBoxes && !detectionRegions.isEmpty {
                            DetectionBoxesOverlayView(
                                regions: detectionRegions,
                                imageSize: image.size
                            )
                        }
                    }
                }

                if zones.isEmpty {
                    VStack {
                        Spacer()
                        Text("No zones defined for this layout")
                            .font(.caption)
                            .foregroundStyle(.gray)
                            .padding(.bottom, 40)
                    }
                } else {
                    VStack(spacing: 10) {
                        Spacer()

                        if showDetectionBoxes && !detectionRegions.isEmpty {
                            DetectionBoxesLegendView()
                        } else if showDetectionBoxes && isLoadingDetectionBoxes {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial, in: Capsule())
                        }

                        if isAdmin {
                            HStack(spacing: 6) {
                                Image(systemName: "hand.tap.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.cyan)
                                Text("Tap a zone to quick-edit assignment (Admin)")
                                    .font(.caption)
                                    .foregroundStyle(.gray)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Zone Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .sheet(item: $selectedZone) { zone in
                ZoneQuickEditSheet(
                    zone: zone,
                    allSKUs: allSKUs,
                    allGroups: allGroups,
                    onSave: onSave
                )
            }
            .task(id: showDetectionBoxes) {
                guard showDetectionBoxes else {
                    detectionRegions = []
                    isLoadingDetectionBoxes = false
                    return
                }
                isLoadingDetectionBoxes = true
                detectionRegions = await DetectionService.shared.proposeRegions(from: image)
                isLoadingDetectionBoxes = false
            }
        }
    }
}

// MARK: - Zone Quick Edit Sheet

private struct ZoneQuickEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var zone: ShelfZone
    let allSKUs: [ProductSKU]
    let allGroups: [LookAlikeGroup]
    let onSave: () -> Void

    @State private var searchText = ""
    @State private var showAssign = false

    private var filteredSKUs: [ProductSKU] {
        let sorted = allSKUs.sorted { $0.name < $1.name }
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.sku.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredGroups: [LookAlikeGroup] {
        let sorted = allGroups.sorted { $0.name < $1.name }
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List {
                infoSection
                quickActionsSection
                if showAssign {
                    skuSection
                    if !allGroups.isEmpty {
                        groupSection
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(zone.name)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search SKUs or groups"
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationContentInteraction(.scrolls)
    }

    private var infoSection: some View {
        Section {
            LabeledContent("Zone", value: zone.name)
            LabeledContent("Position") {
                let r = zone.rect
                Text("\(Int(r.x * 100))%, \(Int(r.y * 100))%  ·  \(Int(r.w * 100))×\(Int(r.h * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Currently") {
                HStack(spacing: 5) {
                    if zone.isAssigned {
                        Image(systemName: zone.assignedSkuId != nil ? "shippingbox.fill" : "square.on.square.dashed")
                            .font(.caption)
                            .foregroundStyle(.blue)
                        Text(zone.assignmentLabel)
                            .font(.subheadline)
                            .foregroundStyle(.blue)
                    } else {
                        Text("Unassigned")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Zone Info")
        }
    }

    private var quickActionsSection: some View {
        Section {
            Button {
                withAnimation { showAssign.toggle() }
            } label: {
                Label(
                    showAssign ? "Hide Assignment Picker" : "Change Assignment",
                    systemImage: showAssign ? "chevron.up" : "tag.fill"
                )
                .font(.subheadline.weight(.medium))
            }

            if zone.isAssigned {
                Button(role: .destructive) {
                    zone.assignedSkuId = nil
                    zone.assignedSkuName = ""
                    zone.assignedGroupId = nil
                    zone.assignedGroupName = ""
                } label: {
                    Label("Remove Assignment", systemImage: "tag.slash")
                }
            }
        } header: {
            Text("Quick Actions")
        }
    }

    private var skuSection: some View {
        Section {
            if filteredSKUs.isEmpty {
                Text("No products match")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                ForEach(filteredSKUs) { sku in
                    Button {
                        zone.assignedSkuId = sku.id
                        zone.assignedSkuName = sku.name
                        zone.assignedGroupId = nil
                        zone.assignedGroupName = ""
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sku.name)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                Text(sku.sku)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if zone.assignedSkuId == sku.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Assign SKU")
        }
    }

    private var groupSection: some View {
        Section {
            ForEach(filteredGroups) { group in
                Button {
                    zone.assignedGroupId = group.id
                    zone.assignedGroupName = group.name
                    zone.assignedSkuId = nil
                    zone.assignedSkuName = ""
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            if !group.notes.isEmpty {
                                Text(group.notes)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        if zone.assignedGroupId == group.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }
        } header: {
            Text("Assign Look-Alike Group")
        }
    }
}
