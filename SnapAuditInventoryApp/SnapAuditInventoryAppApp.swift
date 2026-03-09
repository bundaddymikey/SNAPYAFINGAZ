import SwiftUI
import SwiftData

@main
struct SnapAuditInventoryAppApp: App {
    let container: ModelContainer
    let isInSafeMode: Bool

    init() {
        let schema = Schema([
            AppUser.self,
            Location.self,
            ProductSKU.self,
            ProductLocationLink.self,
            AuditSession.self,
            CapturedMedia.self,
            SampledFrame.self,
            ReferenceMedia.self,
            Embedding.self,
            VerifiedSample.self,
            AuditLineItem.self,
            DetectionEvidence.self,
            ExpectedSnapshot.self,
            ExpectedRow.self,
            InventorySystemSnapshot.self,
            OnHandRow.self,
            LookAlikeGroup.self,
            LookAlikeGroupMember.self,
            ZoneProfile.self,
            ShelfLayout.self,
            ShelfZone.self,
            LayoutAssignmentHistory.self,
        ])

        var resolvedContainer: ModelContainer?
        var inSafeMode = false

        do {
            let persistentConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            resolvedContainer = try ModelContainer(for: schema, configurations: [persistentConfig])
            UserDefaults.standard.set(false, forKey: "LastLaunchFailed")
            UserDefaults.standard.removeObject(forKey: "LastStartupError")
        } catch let persistentError {
            inSafeMode = true
            UserDefaults.standard.set(true, forKey: "LastLaunchFailed")
            UserDefaults.standard.set(persistentError.localizedDescription, forKey: "LastStartupError")

            do {
                let memConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                resolvedContainer = try ModelContainer(for: schema, configurations: [memConfig])
            } catch let memError {
                let combined = "\(persistentError.localizedDescription) | Fallback: \(memError.localizedDescription)"
                UserDefaults.standard.set(combined, forKey: "LastStartupError")
            }
        }

        if let c = resolvedContainer {
            container = c
        } else {
            let minSchema = Schema([AppUser.self])
            let minConfig = ModelConfiguration(schema: minSchema, isStoredInMemoryOnly: true)
            container = (try? ModelContainer(for: minSchema, configurations: [minConfig]))
                ?? { preconditionFailure("Cannot create any ModelContainer") }()
            inSafeMode = true
        }

        isInSafeMode = inSafeMode
    }

    var body: some Scene {
        WindowGroup {
            if isInSafeMode {
                SafeModeView()
                    .modelContainer(container)
            } else {
                ContentView()
                    .modelContainer(container)
            }
        }
    }
}
