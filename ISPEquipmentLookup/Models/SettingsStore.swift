import Foundation

@Observable
class SettingsStore {
    // Stored in UserDefaults
    var ispCookies: String { didSet { ud("ispCookies", ispCookies) } }
    var ispBaseURL: String { didSet { ud("ispBaseURL", ispBaseURL) } }
    var concurrency: Int   { didSet { UserDefaults.standard.set(concurrency, forKey: "concurrency") } }

    init() {
        let d = UserDefaults.standard
        ispCookies  = d.string(forKey: "ispCookies")  ?? ""
        ispBaseURL  = d.string(forKey: "ispBaseURL")  ?? "https://isp.hec.net.sap"
        concurrency = d.integer(forKey: "concurrency")
        if concurrency < 1 { concurrency = 3 }
    }

    var isComplete: Bool { !ispCookies.isEmpty && !ispBaseURL.isEmpty }

    private func ud(_ key: String, _ value: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
