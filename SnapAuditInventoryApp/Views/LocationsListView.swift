import SwiftUI
import SwiftData

struct LocationsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var viewModel: LocationsViewModel
    @State private var showAddLocation = false
    @State private var locationToEdit: Location?
    @State private var showDeleteAlert = false
    @State private var locationToDelete: Location?

    var body: some View {
        List {
            ForEach(viewModel.locations, id: \.id) { location in
                NavigationLink(value: location) {
                    LocationRow(location: location)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        locationToDelete = location
                        showDeleteAlert = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        locationToEdit = location
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.orange)
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if viewModel.locations.isEmpty {
                EmptyStateView(
                    title: "No Shelves",
                    subtitle: "Tap + to add your first shelf",
                    icon: "mappin.and.ellipse"
                )
            }
        }
        .navigationTitle("Shelves")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddLocation = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .navigationDestination(for: Location.self) { location in
            LocationDetailView(location: location)
        }
        .sheet(isPresented: $showAddLocation) {
            LocationFormView(viewModel: viewModel)
        }
        .sheet(item: $locationToEdit) { location in
            LocationFormView(viewModel: viewModel, location: location)
        }
        .alert("Delete Shelf?", isPresented: $showDeleteAlert, presenting: locationToDelete) { location in
            Button("Delete", role: .destructive) { viewModel.deleteLocation(location) }
            Button("Cancel", role: .cancel) { }
        } message: { location in
            Text("This will permanently delete \"\(location.name)\" and all linked products.")
        }
        .onAppear { viewModel.setup(context: modelContext) }
    }
}

struct LocationRow: View {
    let location: Location

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text(location.name)
                    .font(.body.weight(.medium))
                if !location.notes.isEmpty {
                    Text(location.notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text("\(location.productLinks.count)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(.tertiarySystemFill))
                .clipShape(Capsule())
        }
        .padding(.vertical, 2)
    }
}
