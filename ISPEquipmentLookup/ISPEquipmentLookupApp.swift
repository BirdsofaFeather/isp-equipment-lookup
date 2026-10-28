import SwiftUI

@main
struct ISPEquipmentLookupApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainContentView()
                .environment(appState)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1100, height: 700)

        Settings {
            SettingsView().environment(appState)
        }
    }
}
