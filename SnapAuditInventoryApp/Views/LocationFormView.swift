import SwiftUI

struct LocationFormView: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: LocationsViewModel
    let location: Location?

    @State private var name: String
    @State private var notes: String

    init(viewModel: LocationsViewModel, location: Location? = nil) {
        self.viewModel = viewModel
        self.location = location
        _name = State(initialValue: location?.name ?? "")
        _notes = State(initialValue: location?.notes ?? "")
    }

    private var isEditing: Bool { location != nil }
    private var isValid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section("Location Info") {
                    TextField("Location Name", text: $name)
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle(isEditing ? "Edit Location" : "New Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        viewModel.saveLocation(
                            existing: location,
                            name: name.trimmingCharacters(in: .whitespaces),
                            notes: notes.trimmingCharacters(in: .whitespaces)
                        )
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!isValid)
                }
            }
        }
    }
}
