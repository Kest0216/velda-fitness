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
