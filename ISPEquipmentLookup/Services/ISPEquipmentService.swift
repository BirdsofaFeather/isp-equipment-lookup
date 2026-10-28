import Foundation

struct ISPEquipmentService {

    enum ServiceError: LocalizedError {
        case invalidURL
        case sessionTokenNotFound
        case httpError(Int, String)
        case notFound

        var errorDescription: String? {
            switch self {
            case .invalidURL:              return "Invalid base URL"
            case .sessionTokenNotFound:    return "Could not get SAP session token — check cookies"
            case .httpError(let c, let b): return "HTTP \(c)\(b.isEmpty ? "" : ": \(b.prefix(120))")"
            case .notFound:                return "Equipment not found for this serial number"
            }
        }
    }

    struct SessionInfo {
        let token: String
        let moin: String
        // The session cookie string to use for batch calls.
        // Includes sap-usercontext + fresh SAP_SESSIONID obtained from the GET response.
        let cookieHeader: String
    }

    static func acquireToken(settings: SettingsStore,
                              session: URLSession) async throws -> SessionInfo {
        let base = settings.ispBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/sap/bc/gui/sap/its/webgui?~transaction=IH08") else {
            throw ServiceError.invalidURL
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 30
        req.setValue(settings.ispCookies, forHTTPHeaderField: "Cookie")
        req.setValue("text/html,application/xhtml+xml,*/*", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: req)
        let httpResp = response as? HTTPURLResponse
        let status = httpResp?.statusCode ?? -1
        let finalURLStr = httpResp?.url?.absoluteString ?? ""
        let raw = String(data: data, encoding: .utf8) ?? ""

        // Extract ANON URL token
        let token: String
        if let t = extractTokenFromURL(finalURLStr) {
            token = t
        } else {
            let html = htmlUnescape(raw)
            if let t = extractTokenFromURL(html) {
                token = t
            } else if let t = extractTokenFromXML(html) {
                token = t
            } else {
                guard status == 200 || (status >= 300 && status < 400) else {
                    throw ServiceError.httpError(status, String(raw.prefix(200)))
                }
                throw ServiceError.sessionTokenNotFound
            }
        }

        // Extract moin CSRF token from: sap.its.aParams = {...,moin:'XXXXXXXX',...}
        let moin = extractMoin(from: raw) ?? ""

        // Extract the saplbISP load-balancer affinity cookie from Set-Cookie response headers.
        // This cookie pins all subsequent batch requests to the same ITS backend instance
        // that created the ANON session token. Without it, batch calls may hit a different
        // server that doesn't have this session, causing -1002 or value-not-persisted failures.
        let saplbCookie = extractSaplbCookie(from: httpResp)
        let cookieHeader: String
        if let lb = saplbCookie {
            cookieHeader = "\(settings.ispCookies); \(lb)"
        } else {
            cookieHeader = settings.ispCookies
        }

        return SessionInfo(token: token, moin: moin, cookieHeader: cookieHeader)
    }

    // Look up equipment by serial number using IH08 (Equipment List).
    // SAP ITS returns plain XML (not multipart) on the first batch call to a fresh session.
    // A warm-up batch call (state/ur) primes the session so the actual 3-step lookup
    // receives a proper multipart response with the full IE03 screen.
    static func lookup(serialNumber: String, sessionInfo: SessionInfo,
                       settings: SettingsStore,
                       session: URLSession) async throws -> EquipmentRecord {
        let base = settings.ispBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // Warm-up: first batch call always returns plain XML on a fresh session.
        // This primes SAP ITS to return multipart on the next call.
        _ = try? await postBatch(payload: [["get": "state/ur"]], sessionInfo: sessionInfo,
                                  base: base, session: session)

        let payload: [[String: String]] = [
            ["post": "value/wnd[0]/usr/txtSERGE-LOW", "content": serialNumber, "logic": "ignore"],
            ["post": "vkey/8/ses[0]"],
            ["get": "state/ur"],
        ]
        let xml = try await postBatch(payload: payload, sessionInfo: sessionInfo,
                                      base: base, session: session)

        return try parseResponse(xml: xml, requestedSerial: serialNumber)
    }

    // MARK: - Batch POST

    @discardableResult
    private static func postBatch(payload: [[String: String]], sessionInfo: SessionInfo,
                                   base: String,
                                   session: URLSession) async throws -> String {
        guard var comps = URLComponents(
            string: "\(base)/sap(\(sessionInfo.token))/bc/gui/sap/its/webgui/batch/json") else {
            throw ServiceError.invalidURL
        }
        comps.queryItems = [
            URLQueryItem(name: "~RG_WEBGUI",    value: "X"),
            URLQueryItem(name: "sap-statistics", value: "true"),
        ]
        guard let url = comps.url else { throw ServiceError.invalidURL }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue(sessionInfo.cookieHeader,                forHTTPHeaderField: "Cookie")
        req.setValue("application/json;charset=UTF-8",        forHTTPHeaderField: "Content-Type")
        req.setValue("multipart/mixed",                       forHTTPHeaderField: "Accept")
        req.setValue("XMLHttpRequest",                        forHTTPHeaderField: "X-Requested-With")
        req.setValue("true",                                  forHTTPHeaderField: "Sap-Cancel-On-Close")
        req.setValue(base,                                    forHTTPHeaderField: "Origin")
        req.setValue("\(base)/sap/bc/gui/sap/its/webgui",     forHTTPHeaderField: "Referer")
        if !sessionInfo.moin.isEmpty {
            req.setValue(sessionInfo.moin,                    forHTTPHeaderField: "moin")
        }
        req.httpBody = encodeBatchPayload(payload)

        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let rawBody = String(data: data, encoding: .utf8) ?? ""

        guard status == 200 else { throw ServiceError.httpError(status, rawBody) }

        // SAP returns multipart or JSON array depending on Accept header and server version.
        // With Accept: text/xml, the response is a JSON array like:
        //   [{"ord":"1","code":"0","status":"OK"},{"ord":"2","code":"0","content":"<?xml..."}]
        // With Accept: multipart/mixed, each part is a MIME segment.
        if let xmlPart = extractLastXMLPart(from: rawBody) {
            return xmlPart
        }
        if let jsonContent = extractContentFromJSONBatch(from: rawBody) {
            return jsonContent
        }
        return rawBody
    }

    // SAP ITS batch API reads the FIRST key of each step object as the operation type.
    // JSONEncoder sorts keys alphabetically, which puts "content" before "post" — SAP
    // then sees "content" as an unknown tag and returns -1002. Build the JSON manually
    // so "post"/"get" always comes first, then "content", then any remaining keys.
    private static func encodeBatchPayload(_ steps: [[String: String]]) -> Data {
        // Key emission order that SAP expects: post/get first, content second, rest after
        let keyOrder = ["post", "get", "content", "logic"]
        var parts: [String] = []
        for step in steps {
            var fields: [String] = []
            for k in keyOrder {
                if let v = step[k] {
                    fields.append("\"\(k)\":\"\(jsonEscape(v))\"")
                }
            }
            // Any keys not in the ordered list
            for (k, v) in step where !keyOrder.contains(k) {
                fields.append("\"\(k)\":\"\(jsonEscape(v))\"")
            }
            parts.append("{\(fields.joined(separator: ","))}")
        }
        return Data("[\(parts.joined(separator: ","))]".utf8)
    }

    private static func jsonEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Multipart response parsing

    private static func extractLastXMLPart(from body: String) -> String? {
        let boundaryMarker = "--SAP_RESTGUI_BATCH_STEP"
        guard body.contains(boundaryMarker) else { return nil }

        var lastXMLPart: String? = nil
        var remaining = body[body.startIndex...]

        while let boundaryRange = remaining.range(of: boundaryMarker) {
            remaining = remaining[boundaryRange.upperBound...]
            if let newline = remaining.range(of: "\r\n") {
                remaining = remaining[newline.upperBound...]
            } else if let newline = remaining.range(of: "\n") {
                remaining = remaining[newline.upperBound...]
            }
            let partEnd: String.Index
            if let nextBoundary = remaining.range(of: boundaryMarker) {
                partEnd = nextBoundary.lowerBound
            } else {
                partEnd = remaining.endIndex
            }
            let partContent = String(remaining[..<partEnd])
            if partContent.contains("Content-Type: text/xml") ||
               partContent.contains("content-type: text/xml") {
                // Extract just the body after the blank line separator
                if let sep = partContent.range(of: "\r\n\r\n") {
                    lastXMLPart = String(partContent[sep.upperBound...])
                } else if let sep = partContent.range(of: "\n\n") {
                    lastXMLPart = String(partContent[sep.upperBound...])
                } else {
                    lastXMLPart = partContent
                }
            }
        }

        return lastXMLPart
    }

    // Parse a SAP batch JSON response (returned with Accept: text/xml).
    // Format: [{"ord":"N","code":"0","status":"OK","content":"<?xml...>"}]
    // Returns the content of the last step with code 0, or nil if none.
    private static func extractContentFromJSONBatch(from body: String) -> String? {
        guard body.hasPrefix("[{") else { return nil }
        guard let data = body.data(using: .utf8),
              let steps = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        // Find the last step with code 0 and a non-empty content
        let successSteps = steps.filter {
            ($0["code"] as? String) == "0" && !($0["content"] as? String ?? "").isEmpty
        }
        return successSteps.last?["content"] as? String
    }

    static func parseResponse(xml: String, requestedSerial: String) throws -> EquipmentRecord {
        let html = extractCDATA(from: xml)

        guard html.contains("id=\"M0:46:1:1::0:16\"") || html.contains("M0:46:1:1::0:16") else {
            throw ServiceError.notFound
        }

        func inputValue(_ id: String) -> String { extractInputValue(from: html, id: id) }

        let equipNum  = inputValue("M0:46:1:1::0:16")
        let mfgSerial = inputValue("M0:46:2:3B256:3::4:17")

        var record = EquipmentRecord(
            serialNumber:       mfgSerial.isEmpty ? requestedSerial : mfgSerial,
            equipmentNumber:    equipNum,
            description:        inputValue("M0:46:1:2::0:16"),
            userId:             inputValue("M0:46:2:3B256:1::4:62"),
            manufacturer:       inputValue("M0:46:2:3B256:3::1:17"),
            modelNumber:        inputValue("M0:46:2:3B256:3::2:17"),
            acquisitionDate:    inputValue("M0:46:2:3B256:2::1:62"),
            acquisitionValue:   inputValue("M0:46:2:3B256:2::1:17"),
            currency:           inputValue("M0:46:2:3B256:2::1:35"),
            inventoryNo:        inputValue("M0:46:2:3B256:1::5:17"),
            systemStatus:       inputValue("M0:46:1:3::0:16"),
            userStatus:         inputValue("M0:46:1:3::0:47"),
            objectType:         inputValue("M0:46:2:3B256:1:1::0:16"),
            manufacturerPartNo: inputValue("M0:46:2:3B256:3::3:17"),
            validFrom:          inputValue("M0:46:1:4::0:16"),
            category:           inputValue("M0:46:1:1::0:49"),
            queryStatus:        .found)

        if record.equipmentNumber.isEmpty && record.manufacturer.isEmpty {
            record.queryStatus = .notFound
        }
        return record
    }

    // MARK: - Cookie helpers

    // Extract only the sap-usercontext cookie (omits SAP_SESSIONID to force a fresh session).
    private static func extractUserContextCookie(from cookies: String) -> String {
        let parts = cookies.components(separatedBy: ";")
        let userContext = parts
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("sap-usercontext=") }
            .first
        return userContext ?? cookies
    }

    // Extract the saplbISP load-balancer affinity cookie from Set-Cookie response headers.
    // SAP ITS uses this cookie to pin subsequent requests to the same backend instance
    // that issued the ANON session token. Without it, batch calls may round-robin to a
    // different server and fail because the session state is server-local.
    private static func extractSaplbCookie(from response: HTTPURLResponse?) -> String? {
        guard let response = response, let url = response.url else { return nil }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { dict, pair in
            if let key = pair.key as? String, let val = pair.value as? String {
                dict[key] = val
            }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        if let lb = cookies.first(where: { $0.name.hasPrefix("saplb") }) {
            return "\(lb.name)=\(lb.value)"
        }
        return nil
    }

    // MARK: - Token / moin extraction

    static func extractTokenFromURL(_ text: String) -> String? {
        let marker = "/sap("
        guard let start = text.range(of: marker) else { return nil }
        let afterOpen = text[start.upperBound...]
        guard let closeIdx = afterOpen.firstIndex(of: ")") else { return nil }
        let token = String(afterOpen[..<closeIdx])
        guard token.count > 10,
              let nextChar = text[closeIdx...].dropFirst().first,
              nextChar == "/"
        else { return nil }
        return token
    }

    static func extractTokenFromXML(_ text: String) -> String? {
        let open = "<SESSION_TOKEN>"
        let close = "</SESSION_TOKEN>"
        guard let s = text.range(of: open),
              let e = text.range(of: close, range: s.upperBound..<text.endIndex)
        else { return nil }
        let token = String(text[s.upperBound..<e.lowerBound])
        return token.isEmpty ? nil : token
    }

    static func extractMoin(from html: String) -> String? {
        let marker = "moin:'"
        guard let start = html.range(of: marker) else { return nil }
        let after = html[start.upperBound...]
        guard let end = after.firstIndex(of: "'") else { return nil }
        let moin = String(after[..<end])
        return moin.isEmpty ? nil : moin
    }

    // MARK: - HTML/XML helpers

    private static func extractCDATA(from xml: String) -> String {
        var parts: [String] = []
        var remaining = xml[xml.startIndex...]
        let open  = "<![CDATA["
        let close = "]]>"
        while let openRange = remaining.range(of: open) {
            remaining = remaining[openRange.upperBound...]
            if let closeRange = remaining.range(of: close) {
                parts.append(String(remaining[..<closeRange.lowerBound]))
                remaining = remaining[closeRange.upperBound...]
            } else {
                parts.append(String(remaining))
                break
            }
        }
        return parts.joined(separator: "\n")
    }

    private static func extractInputValue(from html: String, id: String) -> String {
        let idAttr = "id=\"\(id)\""
        guard let idRange = html.range(of: idAttr) else { return "" }

        // Search window: a little before the id (for value= attributes in opening tag)
        // and after for lsdata content
        let searchStart = html.index(idRange.lowerBound,
                                     offsetBy: -50,
                                     limitedBy: html.startIndex) ?? html.startIndex
        let searchEnd   = html.index(idRange.upperBound,
                                     offsetBy: 800,
                                     limitedBy: html.endIndex) ?? html.endIndex
        let window = String(html[searchStart..<searchEnd])

        // Try HTML value= attribute
        if let vs = window.range(of: "value=\""),
           let afterVal = Optional(window[vs.upperBound...]),
           let ve = afterVal.firstIndex(of: "\"") {
            return htmlUnescape(String(afterVal[..<ve]))
        }
        // SAP CBS/GuiCTextField stores value in lsdata: "value":"<val>"
        if let vs = window.range(of: "\"value\":\""),
           let afterVal = Optional(window[vs.upperBound...]),
           let ve = afterVal.firstIndex(of: "\"") {
            return htmlUnescape(String(afterVal[..<ve]))
        }
        return ""
    }

    private static func htmlUnescape(_ s: String) -> String {
        var result = s
        // Named entities
        result = result.replacingOccurrences(of: "&amp;",  with: "&")
        result = result.replacingOccurrences(of: "&lt;",   with: "<")
        result = result.replacingOccurrences(of: "&gt;",   with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&apos;", with: "'")
        // Numeric entities: &#xHH; (hex) and &#DDD; (decimal)
        var out = ""
        var i = result.startIndex
        while i < result.endIndex {
            if result[i] == "&", let semi = result[i...].firstIndex(of: ";") {
                let entity = result[result.index(after: i)..<semi]
                if entity.hasPrefix("#x") || entity.hasPrefix("#X"),
                   let codePoint = UInt32(entity.dropFirst(2), radix: 16),
                   let scalar = Unicode.Scalar(codePoint) {
                    out.append(Character(scalar))
                    i = result.index(after: semi)
                    continue
                } else if entity.hasPrefix("#"),
                          let codePoint = UInt32(entity.dropFirst()),
                          let scalar = Unicode.Scalar(codePoint) {
                    out.append(Character(scalar))
                    i = result.index(after: semi)
                    continue
                }
            }
            out.append(result[i])
            i = result.index(after: i)
        }
        return out
    }
}
