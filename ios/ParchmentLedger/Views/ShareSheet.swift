// MARK: - UIKit Share Sheet Bridge
//
// Thin `UIViewControllerRepresentable` wrapper around `UIActivityViewController` for exporting
// generated `.json`, `.md`, and `.txt` files from Recipes, Routine Manager, and Vault.

import SwiftUI
import UIKit

struct IdentifiedShareURL: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
