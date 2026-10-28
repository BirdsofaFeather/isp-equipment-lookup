import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var chromeStatus: String? = nil
    @State private var chromeStatusIsError = false

    var body: some View {
        @Bindable var s = appState.settings

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SAP ISP Settings").font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SettingsSection(title: "Connection") {
                        SettingsField("Base URL", text: $s.ispBaseURL,
                                      placeholder: "https://isp.hec.net.sap")
                    }

                    SettingsSection(title: "Session Cookies") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Import directly from Chrome, or paste cookies manually from your browser's network inspector.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let msg = chromeStatus {
                                        Text(msg)
                                            .font(.caption)
                                            .foregroundStyle(chromeStatusIsError ? Color.red : Color.green)
                                    }
                                }
                                Spacer()
                                Button {
                                    importFromChrome(settings: appState.settings)
                                } label: {
                                    Label("Refresh from Chrome", systemImage: "arrow.clockwise")
                                        .font(.caption)
                                }
                            }

                            TextEditor(text: $s.ispCookies)
                                .font(.system(.caption, design: .monospaced))
                                .frame(minHeight: 80)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator, lineWidth: 1))
                        }
                    }

                    SettingsSection(title: "Performance") {
                        HStack {
                            Text("Concurrent lookups")
                                .font(.callout).foregroundStyle(.secondary)
                                .frame(width: 160, alignment: .trailing)
                            Stepper("\(s.concurrency)", value: $s.concurrency, in: 1...10)
                        }
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                if appState.settings.isComplete {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Ready").font(.caption).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text("Enter base URL and session cookies").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.return)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 520, height: 480)
    }

    private func importFromChrome(settings: SettingsStore) {
        chromeStatus = "Reading Chrome cookies…"
        chromeStatusIsError = false
        Task {
            do {
                let cookies = try ChromeCookieReader.readISPCookies()
                await MainActor.run {
                    settings.ispCookies = cookies
                    chromeStatus = "Cookies imported successfully."
                    chromeStatusIsError = false
                }
            } catch {
                await MainActor.run {
                    chromeStatus = error.localizedDescription
                    chromeStatusIsError = true
                }
            }
        }
    }
}

// MARK: - Helpers

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).fontWeight(.semibold)
            Divider()
            content()
        }
    }
}

struct SettingsField: View {
    let label: String
    @Binding var text: String
    let placeholder: String
    var secure: Bool = false

    init(_ label: String, text: Binding<String>, placeholder: String, secure: Bool = false) {
        self.label = label
        self._text = text
        self.placeholder = placeholder
        self.secure = secure
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.callout)
                .frame(width: 130, alignment: .trailing)
                .foregroundStyle(.secondary)
            if secure {
                SecureField(placeholder, text: $text).textFieldStyle(.roundedBorder)
            } else {
                TextField(placeholder, text: $text).textFieldStyle(.roundedBorder)
            }
        }
    }
}
