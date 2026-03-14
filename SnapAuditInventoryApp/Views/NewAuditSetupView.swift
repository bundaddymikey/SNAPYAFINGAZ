import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct NewAuditSetupView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let authViewModel: AuthViewModel
    let auditViewModel: AuditViewModel
    let onSessionCreated: (AuditSession) -> Void

    @Query(sort: \Location.name) private var locations: [Location]
    @Query private var allSKUs: [ProductSKU]
    @Query private var allLayouts: [ShelfLayout]
    @Query(filter: #Predicate<AuditPreset> { !$0.isBuiltIn }, sort: \AuditPreset.createdAt)
    private var customPresets: [AuditPreset]

    // Preset state
    @State private var selectedBuiltInPresetId: String? = nil
    @State private var selectedCustomPreset: AuditPreset? = nil
    @State private var showSavePresetSheet = false
    @State private var newPresetName: String = ""
    @State private var newPresetDescription: String = ""
    @State private var newPresetIcon: String = "star.fill"
    @AppStorage("lastUsedPresetId") private var lastUsedPresetId: String = ""

    @State private var selectedLocation: Location?
    @State private var selectedMode: CaptureMode = .photo
    @AppStorage("reviewWorkflowDefault") private var reviewLaterDefault: Bool = true
    @AppStorage("defaultCaptureQualityMode") private var defaultCaptureQualityModeRaw: String = CaptureQualityMode.standard.rawValue
    @AppStorage("defaultRecognitionScope") private var defaultRecognitionScopeRaw: String = RecognitionScope.all.rawValue
    @AppStorage("defaultStrictBrandFilter") private var defaultStrictBrandFilter: Bool = true
    @AppStorage("defaultAllowPossibleStragglers") private var defaultAllowPossibleStragglers: Bool = false
    @State private var reviewLater: Bool = true
    @State private var selectedLayout: ShelfLayout? = nil
    @State private var captureQualityMode: CaptureQualityMode = .standard
    @State private var recognitionScope: RecognitionScope = .all
    @State private var mainBrand: String = ""
    @State private var secondaryBrand: String = ""
    @State private var enableSecondaryBrand: Bool = false
    @State private var strictBrandFilter: Bool = true
    @State private var allowPossibleStragglers: Bool = false
    @State private var mainCategory: String = ""
    @State private var mainSubcategory: String = ""

    // Derived subcategory options for the category-limited picker
    private var availableSubcategories: [String] {
        InventoryCategory.subcategories(for: mainCategory)
    }
    @State private var showExpectedImporter = false
    @State private var showOnHandImporter = false
    @State private var showExpectedMapper = false
    @State private var showOnHandMapper = false
    @State private var pendingCSVForExpected: CSVParseResult?
    @State private var pendingCSVForOnHand: CSVParseResult?
    @State private var expectedDraft: CSVImportDraft?
    @State private var onHandDraft: CSVImportDraft?
    @State private var csvError: String?
    @State private var showCSVError = false

    private var skuInfos: [ParsedSKUInfo] {
        allSKUs.map { ParsedSKUInfo(id: $0.id, sku: $0.sku, name: $0.name) }
    }

    private var layoutsForLocation: [ShelfLayout] {
        guard let loc = selectedLocation else { return [] }
        return allLayouts
            .filter { $0.locationId == loc.id }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        List {
            presetWorkflowSection
            locationSection
            captureModeSection
            captureQualitySection
            recognitionScopeSection
            reviewWorkflowSection
            layoutSection
            importSection
            savePresetSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("New Audit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Start") { startAudit() }
                    .fontWeight(.semibold)
                    .disabled(selectedLocation == nil)
            }
        }
        .sensoryFeedback(.selection, trigger: selectedMode)
        .onChange(of: selectedLocation) { _, _ in
            selectedLayout = nil
        }
        .onAppear {
            reviewLater = reviewLaterDefault
            captureQualityMode = CaptureQualityMode(rawValue: defaultCaptureQualityModeRaw) ?? .standard
            recognitionScope = RecognitionScope(rawValue: defaultRecognitionScopeRaw) ?? .all
            strictBrandFilter = defaultStrictBrandFilter
            allowPossibleStragglers = defaultAllowPossibleStragglers
            // Re-apply last used preset if any
            if !lastUsedPresetId.isEmpty,
               let preset = BuiltInPreset.all.first(where: { $0.id == lastUsedPresetId }) {
                applyBuiltIn(preset)
            }
        }
        .fileImporter(
            isPresented: $showExpectedImporter,
            allowedContentTypes: [UTType.commaSeparatedText, UTType.plainText],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result: result, type: .expected)
        }
        .fileImporter(
            isPresented: $showOnHandImporter,
            allowedContentTypes: [UTType.commaSeparatedText, UTType.plainText],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result: result, type: .onHand)
        }
        .sheet(isPresented: $showExpectedMapper) {
            if let parsed = pendingCSVForExpected {
                CSVColumnMapperView(
                    parseResult: parsed,
                    skus: skuInfos,
                    importType: .expected,
                    onConfirm: { draft in
                        expectedDraft = draft
                        showExpectedMapper = false
                    },
                    onCancel: {
                        pendingCSVForExpected = nil
                        showExpectedMapper = false
                    }
                )
            }
        }
        .sheet(isPresented: $showOnHandMapper) {
            if let parsed = pendingCSVForOnHand {
                CSVColumnMapperView(
                    parseResult: parsed,
                    skus: skuInfos,
                    importType: .onHand,
                    onConfirm: { draft in
                        onHandDraft = draft
                        showOnHandMapper = false
                    },
                    onCancel: {
                        pendingCSVForOnHand = nil
                        showOnHandMapper = false
                    }
                )
            }
        }
        .alert("Import Error", isPresented: $showCSVError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(csvError ?? "Could not read the file.")
        }
        .sheet(isPresented: $showSavePresetSheet) {
            NavigationStack {
                Form {
                    Section {
                        TextField("Preset Name", text: $newPresetName)
                        TextField("Description (optional)", text: $newPresetDescription)
                    } header: {
                        Text("Details")
                    }

                    Section {
                        let iconOptions: [(String, String)] = [
                            ("star.fill", "Star"),
                            ("bookmark.fill", "Bookmark"),
                            ("checkmark.seal.fill", "Verified"),
                            ("bolt.fill", "Quick"),
                            ("magnifyingglass", "Scan"),
                            ("cube.box.fill", "Box"),
                            ("tray.fill", "Tray"),
                            ("building.2.fill", "Brand"),
                            ("tag.fill", "Category")
                        ]
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(iconOptions, id: \.0) { icon, label in
                                    Button {
                                        newPresetIcon = icon
                                    } label: {
                                        VStack(spacing: 4) {
                                            Image(systemName: icon)
                                                .font(.title3)
                                                .foregroundStyle(newPresetIcon == icon ? .white : .blue)
                                                .frame(width: 44, height: 44)
                                                .background(newPresetIcon == icon ? Color.blue : Color.blue.opacity(0.12), in: .rect(cornerRadius: 10))
                                            Text(label)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    } header: {
                        Text("Icon")
                    }
                }
                .navigationTitle("Save Preset")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showSavePresetSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            guard !newPresetName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                            let preset = AuditPreset(
                                name: newPresetName,
                                description: newPresetDescription.isEmpty ? "Custom preset" : newPresetDescription,
                                icon: newPresetIcon,
                                recognitionScope: recognitionScope,
                                mainBrand: mainBrand,
                                secondaryBrand: enableSecondaryBrand ? secondaryBrand : "",
                                strictBrandFilter: strictBrandFilter,
                                allowPossibleStragglers: allowPossibleStragglers,
                                captureQualityMode: captureQualityMode,
                                enableAuditTrayMode: UserDefaults.standard.bool(forKey: "auditTrayModeEnabled"),
                                enableMultiScaleDetection: UserDefaults.standard.bool(forKey: "multiScaleDetectionEnabled"),
                                enableContrastiveVariantTraining: UserDefaults.standard.bool(forKey: "contrastiveVariantTrainingEnabled"),
                                enableOCRVariantAssist: UserDefaults.standard.bool(forKey: "ocrAssistedVariantComparison"),
                                reviewWorkflow: selectedWorkflow,
                                isBuiltIn: false
                            )
                            modelContext.insert(preset)
                            try? modelContext.save()
                            selectedCustomPreset = preset
                            selectedBuiltInPresetId = nil
                            showSavePresetSheet = false
                        }
                        .fontWeight(.semibold)
                        .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    // MARK: - Sections

    // MARK: Preset Workflow Section

    private var presetWorkflowSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    // Smart suggestion banner
                    if let suggestion = smartSuggestedPreset {
                        presetCard(
                            id: suggestion.id,
                            name: suggestion.name,
                            description: "Suggested",
                            icon: suggestion.icon,
                            accent: suggestion.accentColor,
                            isSelected: selectedBuiltInPresetId == suggestion.id
                        ) {
                            applyBuiltIn(suggestion)
                        }
                        .overlay(alignment: .topTrailing) {
                            Text("Suggested")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.orange, in: Capsule())
                                .offset(x: 4, y: -6)
                        }
                    }

                    ForEach(BuiltInPreset.all, id: \.id) { preset in
                        presetCard(
                            id: preset.id,
                            name: preset.name,
                            description: preset.description,
                            icon: preset.icon,
                            accent: preset.accentColor,
                            isSelected: selectedBuiltInPresetId == preset.id
                        ) {
                            applyBuiltIn(preset)
                        }
                    }

                    ForEach(customPresets) { preset in
                        presetCard(
                            id: preset.id.uuidString,
                            name: preset.name,
                            description: preset.presetDescription,
                            icon: preset.icon,
                            accent: .teal,
                            isSelected: selectedCustomPreset?.id == preset.id
                        ) {
                            applyCustomPreset(preset)
                        }
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))

            // Inline brand pickers — shown immediately when brand-limited scope is active
            if recognitionScope == .brandLimited {
                let distinctBrands = BrandCatalog.merged(with: allSKUs.map { $0.brand }.filter { !$0.isEmpty })

                brandPickerRow(
                    label: "Brand",
                    brands: distinctBrands,
                    selection: $mainBrand
                )

                Toggle("Add Second Brand", isOn: $enableSecondaryBrand)

                if enableSecondaryBrand {
                    brandPickerRow(
                        label: "Second Brand",
                        brands: distinctBrands.filter { $0 != mainBrand },
                        selection: $secondaryBrand
                    )
                }
            }

        } header: {
            Text("Audit Workflow")
        } footer: {
            if recognitionScope == .brandLimited && mainBrand.isEmpty {
                Label("Select a brand to narrow recognition.", systemImage: "building.2.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if let id = selectedBuiltInPresetId,
               let preset = BuiltInPreset.all.first(where: { $0.id == id }) {
                Label(preset.description, systemImage: preset.icon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let preset = selectedCustomPreset {
                Label(preset.presetDescription, systemImage: preset.icon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Select a preset to auto-configure settings, or configure manually below.")
                    .font(.caption2)
            }
        }
    }

    /// Combined brand selector: existing catalog brands as a Picker + a TextField to enter a brand not yet in the catalog.
    @ViewBuilder
    private func brandPickerRow(label: String, brands: [String], selection: Binding<String>) -> some View {
        let isCustomEntry = !selection.wrappedValue.isEmpty && !brands.contains(selection.wrappedValue)

        Picker(label, selection: selection) {
            Text("Select brand…").tag("")
            ForEach(brands, id: \.self) { brand in
                Text(brand).tag(brand)
            }
            Divider()
            Text("Enter new brand…").tag("__new__")
        }
        .pickerStyle(.menu)
        .onChange(of: selection.wrappedValue) { _, newVal in
            if newVal == "__new__" {
                selection.wrappedValue = ""   // clear so the TextField takes over
            }
        }

        // Show a text field when the user picks "Enter new brand…" or has typed a custom name
        if selection.wrappedValue == "" && isCustomEntry || selection.wrappedValue == "__new__" || isCustomEntry {
            HStack(spacing: 8) {
                Image(systemName: "building.2")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                TextField("New brand name", text: selection)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                if !selection.wrappedValue.isEmpty {
                    Button {
                        selection.wrappedValue = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        } else if selection.wrappedValue.isEmpty {
            // Always show the free-text field when nothing is selected yet (no catalog brands exist)
            if brands.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "building.2")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                    TextField("Brand name", text: selection)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                }
            }
        }
    }

    private func presetCard(id: String, name: String, description: String, icon: String, accent: Color, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isSelected ? .white : accent)
                    .frame(width: 36, height: 36)
                    .background(isSelected ? accent : accent.opacity(0.12), in: .rect(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isSelected ? accent : .primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(width: 112)
            .background(
                isSelected
                    ? accent.opacity(0.1)
                    : Color(.secondarySystemGroupedBackground),
                in: .rect(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? accent : Color(.systemGray5), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isSelected)
    }

    private var savePresetSection: some View {
        Section {
            Button {
                newPresetName = ""
                newPresetDescription = ""
                newPresetIcon = "star.fill"
                showSavePresetSheet = true
            } label: {
                Label("Save Current Setup as Preset", systemImage: "square.and.arrow.down")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.blue)
            }
        } footer: {
            Text("Saves capture mode, recognition scope, brand/category filters, and review behavior.")
                .font(.caption2)
        }
    }

    // MARK: - Apply Preset Logic

    private func applyBuiltIn(_ preset: BuiltInPreset) {
        withAnimation(.spring(response: 0.3)) {
            selectedBuiltInPresetId = preset.id
            selectedCustomPreset = nil
        }
        selectedMode = preset.captureMode
        captureQualityMode = preset.captureQualityMode
        recognitionScope = preset.recognitionScope
        strictBrandFilter = preset.strictBrandFilter
        allowPossibleStragglers = preset.allowPossibleStragglers
        reviewLater = preset.reviewWorkflow == .reviewLater
        // Feature flags written to UserDefaults to flow into pipeline
        UserDefaults.standard.set(preset.enableContrastiveVariantTraining, forKey: "contrastiveVariantTrainingEnabled")
        UserDefaults.standard.set(preset.enableOCRVariantAssist, forKey: "ocrAssistedVariantComparison")
        UserDefaults.standard.set(preset.enableMultiScaleDetection, forKey: "multiScaleDetectionEnabled")
        UserDefaults.standard.set(preset.enableAuditTrayMode, forKey: "auditTrayModeEnabled")
        lastUsedPresetId = preset.id
    }

    private func applyCustomPreset(_ preset: AuditPreset) {
        withAnimation(.spring(response: 0.3)) {
            selectedCustomPreset = preset
            selectedBuiltInPresetId = nil
        }
        captureQualityMode = preset.captureQualityMode
        recognitionScope = preset.recognitionScope
        strictBrandFilter = preset.strictBrandFilter
        allowPossibleStragglers = preset.allowPossibleStragglers
        reviewLater = preset.reviewWorkflow == .reviewLater
        if !preset.mainBrand.isEmpty { mainBrand = preset.mainBrand }
        if !preset.secondaryBrand.isEmpty { secondaryBrand = preset.secondaryBrand; enableSecondaryBrand = true }
        UserDefaults.standard.set(preset.enableContrastiveVariantTraining, forKey: "contrastiveVariantTrainingEnabled")
        UserDefaults.standard.set(preset.enableOCRVariantAssist, forKey: "ocrAssistedVariantComparison")
        UserDefaults.standard.set(preset.enableMultiScaleDetection, forKey: "multiScaleDetectionEnabled")
        UserDefaults.standard.set(preset.enableAuditTrayMode, forKey: "auditTrayModeEnabled")
        preset.lastUsedAt = Date()
    }

    /// Smart suggestion: if a shelf layout is selected → Brand Shelf Audit; if tray mode previously enabled → Tray Count
    private var smartSuggestedPreset: BuiltInPreset? {
        if selectedLayout != nil {
            return BuiltInPreset.all.first { $0.id == "brand_shelf_audit" }
        }
        if UserDefaults.standard.bool(forKey: "auditTrayModeEnabled") {
            return BuiltInPreset.all.first { $0.id == "tray_count_high_accuracy" }
        }
        return nil
    }

    // MARK: - Sections

    private var locationSection: some View {
        Section {
            if locations.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "mappin.slash")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No Shelves")
                            .font(.subheadline.weight(.medium))
                        Text("Add a shelf before starting an audit")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } else {
                Picker("Shelf", selection: $selectedLocation) {
                    Text("Select…").tag(nil as Location?)
                    ForEach(locations) { location in
                        Text(location.name).tag(location as Location?)
                    }
                }
            }
        } header: {
            Text("Shelf")
        }
    }

    private var recognitionScopeSection: some View {
        Section {
            Picker("Recognition Scope", selection: $recognitionScope) {
                ForEach(RecognitionScope.allCases, id: \.self) { scope in
                    Label(scope.displayName, systemImage: scope.icon).tag(scope)
                }
            }
            .pickerStyle(.menu)

            if recognitionScope == .brandLimited {
                let distinctBrands = BrandCatalog.merged(with: allSKUs.map { $0.brand }.filter { !$0.isEmpty })

                Picker("Main Brand", selection: $mainBrand) {
                    Text("Select… ").tag("")
                    ForEach(distinctBrands, id: \.self) { brand in
                        Text(brand).tag(brand)
                    }
                }
                .pickerStyle(.menu)

                Toggle("Enable Secondary Brand", isOn: $enableSecondaryBrand)

                if enableSecondaryBrand {
                    Picker("Secondary Brand", selection: $secondaryBrand) {
                        Text("Select… ").tag("")
                        ForEach(distinctBrands.filter { $0 != mainBrand }, id: \.self) { brand in
                            Text(brand).tag(brand)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Toggle("Strict Brand Filter", isOn: $strictBrandFilter)

                if !strictBrandFilter {
                    Toggle("Allow Possible Stragglers", isOn: $allowPossibleStragglers)
                }
            }
            if recognitionScope == .categoryLimited {
                Picker("Main Category", selection: $mainCategory) {
                    Text("Select…").tag("")
                    ForEach(InventoryCategory.allCases, id: \.self) { cat in
                        Text(cat.displayName).tag(cat.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: mainCategory) { _, _ in mainSubcategory = "" }

                if !mainCategory.isEmpty && !availableSubcategories.isEmpty {
                    Picker("Subcategory", selection: $mainSubcategory) {
                        Text("Any").tag("")
                        ForEach(availableSubcategories, id: \.self) { sub in
                            Text(sub).tag(sub)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
        } header: {
            Text("Recognition Scope")
        } footer: {
            switch recognitionScope {
            case .all:
                Text("Searches the full product catalog during recognition.")
                    .font(.caption2)
            case .categoryLimited:
                if mainCategory.isEmpty {
                    Label("Select a category to narrow recognition.", systemImage: "tag.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else {
                    Text("Searches \(mainCategory)\(mainSubcategory.isEmpty ? "" : " → \(mainSubcategory)") only.")
                        .font(.caption2)
                }
            case .brandLimited:
                Text(strictBrandFilter
                    ? "Only products from the selected brand(s) will be considered."
                    : "Selected brands are strongly preferred. Stragglers may appear if confidence is very high.")
                .font(.caption2)
            }
        }
    }

    private var captureModeSection: some View {
        Section {
            ForEach(CaptureMode.allCases, id: \.self) { mode in
                Button {
                    selectedMode = mode
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: mode.icon)
                            .font(.title3.weight(.medium))
                            .foregroundStyle(selectedMode == mode ? .white : .blue)
                            .frame(width: 40, height: 40)
                            .background(selectedMode == mode ? Color.blue : Color.blue.opacity(0.12))
                            .clipShape(.rect(cornerRadius: 10))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(mode.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if selectedMode == mode {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.blue)
                                .font(.title3)
                        }
                    }
                }
            }
        } header: {
            Text("Capture Mode")
        }
    }

    private var captureQualitySection: some View {
        Section {
            ForEach(CaptureQualityMode.allCases, id: \.self) { mode in
                Button {
                    captureQualityMode = mode
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: mode.icon)
                            .font(.title3.weight(.medium))
                            .foregroundStyle(captureQualityMode == mode ? .white : .teal)
                            .frame(width: 40, height: 40)
                            .background(captureQualityMode == mode ? Color.teal : Color.teal.opacity(0.12))
                            .clipShape(.rect(cornerRadius: 10))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(mode.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if captureQualityMode == mode {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.teal)
                                .font(.title3)
                        }
                    }
                }
            }

            if captureQualityMode == .highAccuracy {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(CaptureGuidanceTip.highAccuracyTips) { tip in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: tip.icon)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.teal)
                                .frame(width: 18, height: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tip.title)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(tip.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.top, 8)
            }
        } header: {
            Text("Capture Quality Mode")
        } footer: {
            Text(captureQualityMode == .highAccuracy ? "Use this when auditing loose products on a plain surface for cleaner spacing and more reliable detections." : "Standard mode works best for typical shelf captures and faster audit setup.")
                .font(.caption2)
        }
    }

    private var reviewWorkflowSection: some View {
        Section {
            ForEach(ReviewWorkflow.allCases, id: \.self) { workflow in
                Button {
                    reviewLater = (workflow == .reviewLater)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: workflow.icon)
                            .font(.title3.weight(.medium))
                            .foregroundStyle(selectedWorkflow == workflow ? .white : .indigo)
                            .frame(width: 40, height: 40)
                            .background(selectedWorkflow == workflow ? Color.indigo : Color.indigo.opacity(0.12))
                            .clipShape(.rect(cornerRadius: 10))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(workflow.displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(workflow.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if selectedWorkflow == workflow {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.indigo)
                                .font(.title3)
                        }
                    }
                }
            }
        } header: {
            Text("Review Workflow")
        } footer: {
            Text("Review Later is recommended for large audits.")
                .font(.caption2)
        }
    }

    @ViewBuilder
    private var layoutSection: some View {
        Section {
            if selectedLocation == nil {
                HStack(spacing: 12) {
                    Image(systemName: "rectangle.split.3x1")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                    Text("Select a shelf first")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if layoutsForLocation.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "rectangle.split.3x1")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No layouts at this shelf")
                            .font(.subheadline)
                        Text("Add shelf layouts in the Shelves section")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                layoutPickerRow
            }
        } header: {
            Text("Shelf Layout (Optional)")
        } footer: {
            if selectedLayout != nil {
                Text("Classification will be limited to each zone's assigned SKU, speeding up audits on organized shelves.")
                    .font(.caption2)
            } else {
                Text("Choose a layout to restrict each region to its zone's assigned SKU.")
                    .font(.caption2)
            }
        }
    }

    private var layoutPickerRow: some View {
        HStack(spacing: 12) {
            Image(systemName: selectedLayout != nil ? "checkmark.circle.fill" : "rectangle.split.3x1")
                .font(.body)
                .foregroundStyle(selectedLayout != nil ? .green : .blue)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("Shelf Layout")
                    .font(.subheadline)
                if let layout = selectedLayout {
                    Text("\(layout.name) · \(layout.zones.count) zones · \(layout.assignedZoneCount) assigned")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("None selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Menu {
                Button {
                    selectedLayout = nil
                } label: {
                    Label("None", systemImage: "xmark.circle")
                }
                Divider()
                ForEach(layoutsForLocation) { layout in
                    Button {
                        selectedLayout = layout
                    } label: {
                        HStack {
                            Text(layout.name)
                            if selectedLayout?.id == layout.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Text(selectedLayout == nil ? "Select" : "Change")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.blue.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)

            if selectedLayout != nil {
                Button {
                    selectedLayout = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.body)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }

    private var importSection: some View {
        Section {
            importRow(
                title: "Expected Counts",
                subtitle: expectedDraft.map { "\($0.filename) · \($0.matchedCount) matched" } ?? "Import CSV to guide classification",
                icon: "doc.text.magnifyingglass",
                color: .blue,
                draft: expectedDraft,
                importAction: { showExpectedImporter = true },
                removeAction: { expectedDraft = nil }
            )

            importRow(
                title: "Inventory On Hand",
                subtitle: onHandDraft.map { "\($0.filename) · \($0.matchedCount) matched" } ?? "Optional: import for reconciliation",
                icon: "cube.box.fill",
                color: .teal,
                draft: onHandDraft,
                importAction: { showOnHandImporter = true },
                removeAction: { onHandDraft = nil }
            )
        } header: {
            Text("Expected Data (Optional)")
        } footer: {
            Text("Importing expected counts focuses classification on known SKUs and speeds up audits.")
                .font(.caption2)
        }
    }

    private func importRow(
        title: String,
        subtitle: String,
        icon: String,
        color: Color,
        draft: CSVImportDraft?,
        importAction: @escaping () -> Void,
        removeAction: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: draft != nil ? "checkmark.circle.fill" : icon)
                .font(.body)
                .foregroundStyle(draft != nil ? .green : color)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if draft != nil {
                Button {
                    removeAction()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.body)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    importAction()
                } label: {
                    Text("Import")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(color.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Logic

    private var selectedWorkflow: ReviewWorkflow {
        reviewLater ? .reviewLater : .reviewAsYouGo
    }

    private func handleFileImport(result: Result<[URL], Error>, type: CSVImportType) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                csvError = "Permission denied to access this file."
                showCSVError = true
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let parsed = CSVImportService.shared.parse(text: text, filename: url.lastPathComponent)
                guard !parsed.headers.isEmpty else {
                    csvError = "The file appears empty or is not a valid CSV."
                    showCSVError = true
                    return
                }
                switch type {
                case .expected:
                    pendingCSVForExpected = parsed
                    showExpectedMapper = true
                case .onHand:
                    pendingCSVForOnHand = parsed
                    showOnHandMapper = true
                }
            } catch {
                csvError = "Could not read file: \(error.localizedDescription)"
                showCSVError = true
            }
        case .failure(let error):
            csvError = error.localizedDescription
            showCSVError = true
        }
    }

    private func startAudit() {
        guard let location = selectedLocation,
              let user = authViewModel.currentUser else { return }

        auditViewModel.setup(context: modelContext)

        guard let session = auditViewModel.createSession(
            locationId: location.id,
            locationName: location.name,
            userId: user.id,
            userName: user.name,
            mode: selectedMode,
            reviewWorkflow: selectedWorkflow,
            captureQualityMode: captureQualityMode,
            selectedLayoutId: selectedLayout?.id,
            selectedLayoutName: selectedLayout?.name ?? "",
            recognitionScope: recognitionScope,
            mainBrand: mainBrand,
            secondaryBrand: enableSecondaryBrand ? secondaryBrand : "",
            strictBrandFilter: strictBrandFilter,
            allowPossibleStragglers: allowPossibleStragglers,
            mainCategory: mainCategory,
            mainSubcategory: mainSubcategory,
            presetName: selectedBuiltInPresetId.flatMap { id in BuiltInPreset.all.first { $0.id == id }?.name } ?? selectedCustomPreset?.name ?? "",
            presetIdRaw: selectedBuiltInPresetId ?? selectedCustomPreset?.id.uuidString ?? ""
        ) else { return }

        if let draft = expectedDraft {
            auditViewModel.attachExpectedSnapshot(to: session, draft: draft, skuInfos: skuInfos)
        }
        if let draft = onHandDraft {
            auditViewModel.attachOnHandSnapshot(to: session, draft: draft, skuInfos: skuInfos)
        }

        onSessionCreated(session)
    }
}
