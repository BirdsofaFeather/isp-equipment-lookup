import Foundation

@Observable
class SettingsStore {
    // Stored in UserDefaults
    var ispCookies: String { didSet { ud("ispCookies", ispCookies) } }
    var ispBaseURL: String { didSet { ud("ispBaseURL", ispBaseURL) } }
    var concurrency: Int   { didSet { UserDefaults.standard.set(concurrency, forKey: "concurrency") } }
    var batchSize: Int     { didSet { UserDefaults.standard.set(batchSize,   forKey: "batchSize") } }

    init() {
        let d = UserDefaults.standard
        ispCookies  = d.string(forKey: "ispCookies")  ?? ""
        ispBaseURL  = d.string(forKey: "ispBaseURL")  ?? "https://isp.hec.net.sap"
        let c = d.integer(forKey: "concurrency")
        concurrency = c < 1 ? 3 : c
        let b = d.integer(forKey: "batchSize")
        batchSize   = b < 1 || b > 8 ? 8 : b
    }

    var isComplete: Bool { !ispCookies.isEmpty && !ispBaseURL.isEmpty }

    private func ud(_ key: String, _ value: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
