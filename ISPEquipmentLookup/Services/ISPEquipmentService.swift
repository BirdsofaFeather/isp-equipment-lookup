import Foundation

struct ISPEquipmentService {

    enum ServiceError: LocalizedError {
        case invalidURL
        case sessionTokenNotFound
        case httpError(Int, String)
        case notFound
        case restricted(String)  // in SAP but user lacks authorization to view detail

        var errorDescription: String? {
            switch self {
            case .invalidURL:              return "Invalid base URL"
            case .sessionTokenNotFound:    return "Could not get SAP session token — check cookies"
            case .httpError(let c, let b): return "HTTP \(c)\(b.isEmpty ? "" : ": \(b.prefix(120))")"
            case .notFound:                return "Equipment not found for this serial number"
            case .restricted(let equip):   return "Restricted — Equipment \(equip) exists but you lack authorization to view it"
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

    static func acquireTokenForTransaction(_ transaction: String, settings: SettingsStore,
                                           session: URLSession) async throws -> SessionInfo {
        let base = settings.ispBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/sap/bc/gui/sap/its/webgui?~transaction=\(transaction)") else {
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

        let token: String
        if let t = extractTokenFromURL(finalURLStr) {
            token = t
        } else {
            let html = htmlUnescape(raw)
            if let t = extractTokenFromURL(html) { token = t }
            else if let t = extractTokenFromXML(html) { token = t }
            else {
                guard status == 200 || (status >= 300 && status < 400) else {
                    throw ServiceError.httpError(status, String(raw.prefix(200)))
                }
                throw ServiceError.sessionTokenNotFound
            }
        }
        let moin = extractMoin(from: raw) ?? ""
        let saplbCookie = extractSaplbCookie(from: httpResp)
        let cookieHeader = saplbCookie.map { "\(settings.ispCookies); \($0)" } ?? settings.ispCookies
        return SessionInfo(token: token, moin: moin, cookieHeader: cookieHeader)
    }

    // Look up a known equipment number directly via IE03 — used when IH08 returns multiple
    // results and we've already identified the best equipment number from the ALV grid.
    static func lookupByEquipmentNumber(_ equipmentNumber: String,
                                        requestedSerial: String,
                                        sessionInfo: SessionInfo,
                                        settings: SettingsStore,
                                        session: URLSession) async throws -> EquipmentRecord {
        let base = settings.ispBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        _ = try? await postBatch(payload: [["get": "state/ur"]], sessionInfo: sessionInfo,
                                  base: base, session: session)
        let payload: [[String: String]] = [
            ["post": "value/wnd[0]/usr/txtRIEQUI-EQUNR", "content": equipmentNumber, "logic": "ignore"],
            ["post": "vkey/0/ses[0]"],
            ["get": "state/ur"],
        ]
        let xml = try await postBatch(payload: payload, sessionInfo: sessionInfo,
                                      base: base, session: session)
        return try parseResponse(xml: xml, requestedSerial: requestedSerial, restrictedReason: nil)
    }

    static func lookup(serialNumber: String, sessionInfo: SessionInfo,
                       settings: SettingsStore,
                       session: URLSession) async throws -> EquipmentRecord {
        let base = settings.ispBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // Warm-up: first batch call always returns plain XML on a fresh session.
        _ = try? await postBatch(payload: [["get": "state/ur"]], sessionInfo: sessionInfo,
                                  base: base, session: session)

        let payload: [[String: String]] = [
            ["post": "value/wnd[0]/usr/txtSERGE-LOW", "content": serialNumber, "logic": "ignore"],
            ["post": "vkey/8/ses[0]"],
            ["get": "state/ur"],
        ]
        var xml = try await postBatch(payload: payload, sessionInfo: sessionInfo,
                                      base: base, session: session)

        let safeName = serialNumber.replacingOccurrences(of: "/", with: "_")
        try? xml.write(toFile: "/tmp/isp_lookup_\(safeName).xml", atomically: true, encoding: .utf8)

        // SAP may show a SAPMSSY0 modal popup (wnd[1]) when the user lacks authorization
        // for all selected objects. Capture the reason text, dismiss the popup with Enter,
        // then re-fetch state to get the equipment number from the underlying IE03 screen.
        if isAuthPopupScreen(xml: xml) {
            let popupReason = extractPopupMessage(from: xml)
            let dismissPayload: [[String: String]] = [
                ["post": "vkey/0/ses[0]"],
                ["get": "state/ur"],
            ]
            let afterXml = try await postBatch(payload: dismissPayload, sessionInfo: sessionInfo,
                                               base: base, session: session)
            return try parseResponse(xml: afterXml, requestedSerial: serialNumber,
                                     restrictedReason: popupReason)
        }

        // SAP returns a full-screen ALV grid (SAPLSLVC_FULLSCREEN) when more than one
        // equipment record matches the serial. Pick the row with the highest equipment
        // number (numerically largest = most recently created) and double-click into it.
        if isALVListScreen(xml: xml) {
            let rows = extractALVEquipmentRows(from: xml)
            guard let best = rows.max(by: {
                (Int($0.equip) ?? 0) < (Int($1.equip) ?? 0)
            }) else {
                throw ServiceError.notFound
            }
            // We have the equipment number — start a fresh IE03 session and look it up directly.
            let ie03Session = URLSession(configuration: .ephemeral)
            let ie03Info = try await acquireTokenForTransaction("IE03", settings: settings,
                                                                session: ie03Session)
            return try await lookupByEquipmentNumber(best.equip, requestedSerial: serialNumber,
                                                     sessionInfo: ie03Info, settings: settings,
                                                     session: ie03Session)
        }

        return try parseResponse(xml: xml, requestedSerial: serialNumber, restrictedReason: nil)
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

    // MARK: - Screen detection helpers

    // Returns true when SAP landed on SAPMSSY0 — the system message popup screen.
    // This fires when the user lacks authorization for all selected objects.
    private static func isAuthPopupScreen(xml: String) -> Bool {
        xml.contains("dynpro:'SAPMSSY0'") || xml.contains("dynpro:\"SAPMSSY0\"")
    }

    // Extract the human-readable message text from the SAP system message popup (wnd[1]).
    // The text is in a GuiMessageWindow or GuiLabel inside wnd[1]; we capture whatever
    // displayable text is in that window's CDATA.
    private static func extractPopupMessage(from xml: String) -> String {
        let html = extractCDATA(from: xml)
        // Look for "You do not have authorization..." or any message in wnd[1]
        // The message text is in a value= or lsdata "5": attribute near wnd[1]
        let pattern = #"wnd\[1\].*?value="([^"]{10,}?)""#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators),
           let match = regex.firstMatch(in: html,
                                        range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            return htmlUnescape(String(html[range]))
        }
        // Fallback: look for the known authorization message text
        let authMsg = "You do not have authorization for all the selected"
        if html.contains(authMsg) {
            // Try to find the full sentence
            if let start = html.range(of: authMsg) {
                let from = start.lowerBound
                let to   = html.index(from,
                                      offsetBy: 120,
                                      limitedBy: html.endIndex) ?? html.endIndex
                return htmlUnescape(String(html[from..<to]))
                    .replacingOccurrences(of: "\"", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return authMsg
        }
        return "Authorization restricted"
    }

    // Returns true when SAP returned a full-screen ALV grid (SAPLSLVC_FULLSCREEN)
    // — this happens when IH08 finds more than one equipment record for the serial.
    private static func isALVListScreen(xml: String) -> Bool {
        xml.contains("dynpro:'SAPLSLVC_FULLSCREEN'") ||
        xml.contains("dynpro:\"SAPLSLVC_FULLSCREEN\"")
    }

    struct ALVRow {
        let equip: String  // equipment number string, e.g. "35581906"
        let sid: String    // SID to pass as action/3/<sid>, e.g. "wnd[0]/usr/cntlGRID1/..."
        let rowIndex: Int
    }

    // Extract equipment numbers and their row SIDs from the SAPLSLVC_FULLSCREEN ALV grid.
    //
    // Equipment number cells have id="grid#C105#ROW,COL#if" and lsdata='{"5":"EQUIP_NUM",...}'.
    // The COL in the element id maps to cell[COL-1] in the SID:
    //   wnd[0]/usr/cntlGRID1/shellcont/shell/shellcont[1]/shell/rowcol/row[ROW]/cell[COL-1]
    private static func extractALVEquipmentRows(from xml: String) -> [ALVRow] {
        let html = extractCDATA(from: xml)
        var rows: [ALVRow] = []

        // Match: id="grid#C105#ROW,COL#if" ... lsdata='{"5":"EQUIP_NUM",...}'
        // Both attributes appear on the same element within a few hundred characters.
        guard let regex = try? NSRegularExpression(
            pattern: #"id="grid#C105#(\d+),(\d+)#if"[^>]{0,600}lsdata='(\{[^']+\})'"#,
            options: .dotMatchesLineSeparators) else { return rows }

        let range = NSRange(html.startIndex..., in: html)
        regex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match = match,
                  let rowRange = Range(match.range(at: 1), in: html),
                  let colRange = Range(match.range(at: 2), in: html),
                  let ldRange  = Range(match.range(at: 3), in: html)
            else { return }

            let rowIdx = Int(html[rowRange]) ?? 0
            let colIdx = Int(html[colRange]) ?? 0
            let lsdata = htmlUnescape(String(html[ldRange]))

            guard let valMatch = try? NSRegularExpression(pattern: #""5":"(\d{7,8})""#)
                    .firstMatch(in: lsdata, range: NSRange(lsdata.startIndex..., in: lsdata)),
                  let valRange = Range(valMatch.range(at: 1), in: lsdata)
            else { return }

            let equip = String(lsdata[valRange])
            // SID for the row selection cell ends with rowcol/row[N]/ (no cell index).
            // Clicking it selects the row; then F2 (vkey/2) opens IE03 for that row.
            let sid = "wnd[0]/usr/cntlGRID1/shellcont/shell/shellcont[1]/shell/rowcol/row[\(rowIdx)]/"

            if !rows.contains(where: { $0.equip == equip }) {
                rows.append(ALVRow(equip: equip, sid: sid, rowIndex: rowIdx))
            }
        }

        return rows
    }

    static func parseResponse(xml: String, requestedSerial: String,
                              restrictedReason: String?) throws -> EquipmentRecord {
        let html = extractCDATA(from: xml)

        guard html.contains("id=\"M0:46:1:1::0:16\"") || html.contains("M0:46:1:1::0:16") else {
            // If we already know this is a restricted access case, return restricted stub
            // even if IE03 didn't load properly after popup dismissal.
            if let reason = restrictedReason {
                var record = EquipmentRecord.stub(serialNumber: requestedSerial)
                record.queryStatus = .restricted
                record.error = reason.isEmpty ? "Authorization restricted" : reason
                return record
            }
            throw ServiceError.notFound
        }

        func inputValue(_ id: String) -> String { extractInputValue(from: html, id: id) }

        let equipNum = inputValue("M0:46:1:1::0:16")

        // If we arrived here via a restricted popup, tag the record as restricted
        // but still capture all available fields from the IE03 screen.
        if let reason = restrictedReason {
            var record = EquipmentRecord(
                serialNumber:       requestedSerial,
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
                queryStatus:        .restricted)
            record.error = reason.isEmpty ? "Authorization restricted" : reason
            return record
        }

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
