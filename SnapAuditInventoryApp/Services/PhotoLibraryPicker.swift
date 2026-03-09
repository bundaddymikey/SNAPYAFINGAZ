import SwiftUI
import PhotosUI

struct PhotoLibraryPicker: UIViewControllerRepresentable {
    let onSelect: @MainActor ([UIImage]) -> Void
    var maxItems: Int = 8

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = max(1, maxItems)
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onSelect: @MainActor ([UIImage]) -> Void
        init(onSelect: @escaping @MainActor ([UIImage]) -> Void) { self.onSelect = onSelect }

        nonisolated func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            Task { @MainActor in
                picker.dismiss(animated: true)
            }
            guard !results.isEmpty else {
                Task { @MainActor in self.onSelect([]) }
                return
            }
            Task {
                var images: [UIImage] = []
                for result in results {
                    if result.itemProvider.canLoadObject(ofClass: UIImage.self) {
                        let image = await withCheckedContinuation { cont in
                            result.itemProvider.loadObject(ofClass: UIImage.self) { obj, _ in
                                cont.resume(returning: obj as? UIImage)
                            }
                        }
                        if let image { images.append(image) }
                    }
                }
                let selectedImages = images
                await MainActor.run { self.onSelect(selectedImages) }
            }
        }
    }
}
