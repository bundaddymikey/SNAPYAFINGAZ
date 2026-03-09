import SwiftUI
import SwiftData

@Observable
@MainActor
class LocationsViewModel {
    var locations: [Location] = []

    private var modelContext: ModelContext?

    func setup(context: ModelContext) {
        self.modelContext = context
        fetchLocations()
    }

    func fetchLocations() {
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<Location>(sortBy: [SortDescriptor(\.name)])
        locations = (try? modelContext.fetch(descriptor)) ?? []
    }

    func saveLocation(existing: Location? = nil, name: String, notes: String) {
        guard let modelContext else { return }
        if let existing {
            existing.name = name
            existing.notes = notes
        } else {
            let location = Location(name: name, notes: notes)
            modelContext.insert(location)
        }
        try? modelContext.save()
        fetchLocations()
    }

    func deleteLocation(_ location: Location) {
        guard let modelContext else { return }
        modelContext.delete(location)
        try? modelContext.save()
        fetchLocations()
    }
}
