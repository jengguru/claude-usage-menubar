import SwiftUI

@main
struct ClaudeMeterApp: App {
    @StateObject private var store: UsageStore

    init() {
        AppSettings.registerDefaults()
        _store = StateObject(wrappedValue: UsageStore())
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}
