import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    let applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#elseif canImport(AppKit)
struct ActivityView: NSViewRepresentable {
    let activityItems: [Any]

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            presentPicker(from: view, context: context)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard !context.coordinator.didPresent else { return }
        DispatchQueue.main.async {
            presentPicker(from: nsView, context: context)
        }
    }

    private func presentPicker(from view: NSView, context: Context) {
        guard !context.coordinator.didPresent else { return }
        context.coordinator.didPresent = true
        let picker = NSSharingServicePicker(items: activityItems)
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    final class Coordinator {
        var didPresent = false
    }
}
#endif
