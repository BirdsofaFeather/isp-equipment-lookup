import Foundation

@MainActor
@Observable
class AppState {
    var settings = SettingsStore()
    var vm = LookupViewModel()
}
