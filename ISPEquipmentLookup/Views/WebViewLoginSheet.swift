import SwiftUI
import WebKit

// Opens the ISP WebGUI login URL in an embedded WKWebView.
// After the user authenticates, captures sap-usercontext and SAP_SESSIONID
// from the WKHTTPCookieStore and writes them to SettingsStore.ispCookies.
//
// NOTE: This will NOT work if SAP ITS requires device compliance via Azure AD
// Conditional Access — embedded WebViews don't inherit the system's compliance
// token. If login redirects to an error page, use the manual cookie paste instead.

struct WebViewLoginSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var status: String = "Loading…"
    @State private var captured: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sign in to SAP ISP").font(.headline)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(captured ? .green : .secondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 10)

            Divider()

            // WebView
            ISPWebView(baseURL: appState.settings.ispBaseURL) { cookies in
                appState.settings.ispCookies = cookies
                captured = true
                status = "Cookies captured — you can close this window."
            } onNavigate: { url in
                status = url
            }

            Divider()

            HStack {
                if captured {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Session cookies saved automatically.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text("Complete login in the window above.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.return)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 900, height: 680)
    }
}

// MARK: - WKWebView wrapper

private struct ISPWebView: NSViewRepresentable {
    let baseURL: String
    let onCookiesCaptured: (String) -> Void
    let onNavigate: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCookiesCaptured: onCookiesCaptured, onNavigate: onNavigate)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Use a non-persistent store so credentials don't linger, but cookies within
        // the session are available for extraction.
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.baseURL = baseURL

        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let url = URL(string: "\(base)/sap/bc/gui/sap/its/webgui?~transaction=IH08") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// MARK: - Coordinator / navigation delegate

private class Coordinator: NSObject, WKNavigationDelegate {
    let onCookiesCaptured: (String) -> Void
    let onNavigate: (String) -> Void
    weak var webView: WKWebView?
    var baseURL: String = ""
    private var didCapture = false

    init(onCookiesCaptured: @escaping (String) -> Void,
         onNavigate: @escaping (String) -> Void) {
        self.onCookiesCaptured = onCookiesCaptured
        self.onNavigate = onNavigate
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let urlStr = webView.url?.absoluteString ?? ""
        onNavigate(urlStr)
        extractCookiesIfReady(from: webView)
    }

    func webView(_ webView: WKWebView,
                 didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        extractCookiesIfReady(from: webView)
    }

    private func extractCookiesIfReady(from webView: WKWebView) {
        guard !didCapture else { return }
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let currentURL = webView.url?.absoluteString,
              currentURL.contains(base) else { return }

        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self = self, !self.didCapture else { return }

            let sapCookies = cookies.filter {
                $0.name == "sap-usercontext" || $0.name == "SAP_SESSIONID"
            }
            guard !sapCookies.isEmpty else { return }

            let cookieString = sapCookies
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")

            self.didCapture = true
            DispatchQueue.main.async {
                self.onCookiesCaptured(cookieString)
            }
        }
    }
}
