import SwiftUI
import SwiftData

struct ShelfLayoutFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let locationId: UUID
    let existing: ShelfLayout?

    @State private var name: String
    @State private var notes: String

    init(locationId: UUID, existing: ShelfLayout? = nil) {
        self.locationId = locationId
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _notes = State(initialValue: existing?.notes ?? "")
    }

    private var isValid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section("Layout Info") {
                    TextField("Layout Name", text: $name)
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.blue)
                        Text("After creating the layout, open it to add zones and assign SKUs to each zone.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(existing != nil ? "Edit Layout" : "New Layout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(!isValid)
                }
            }
        }
    }

    private func save() {
        let trimName = name.trimmingCharacters(in: .whitespaces)
        let trimNotes = notes.trimmingCharacters(in: .whitespaces)
        if let existing {
            existing.name = trimName
            existing.notes = trimNotes
        } else {
            let layout = ShelfLayout(name: trimName, locationId: locationId, notes: trimNotes)
            modelContext.insert(layout)
        }
        try? modelContext.save()
        dismiss()
    }
}
