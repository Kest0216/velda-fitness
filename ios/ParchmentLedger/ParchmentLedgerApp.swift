// MARK: - App Entrypoint
//
// Owns the single root `LedgerStore` instance and locks the app to `.light` mode so the warm
// parchment paper palette and ink typography remain consistent regardless of system appearance.

import SwiftUI

@main
struct ParchmentLedgerApp: App {
    @StateObject private var store = LedgerStore()

    var body: some Scene {
        WindowGroup {
            RootLedgerView()
                .environmentObject(store)
                .preferredColorScheme(.light)
        }
    }
}
