# ISP Equipment Lookup

A macOS SwiftUI app that looks up SAP equipment records by device serial number, using SAP WebGUI ITS (transaction IH08).

## What it does

Enter one or more device serial numbers. The app queries your SAP ISP system and returns the SAP Equipment number, description, assigned user, manufacturer, model, acquisition date/value, and status for each device.

**Input modes:** Single serial number · Paste list · Import CSV  
**Output:** In-app results table with Export CSV / Export JSON

---

## Setup

1. Build and run in Xcode (macOS 13+, Swift 5.9+).
2. Open **Settings** (gear icon) and fill in:
   - **Base URL** — your SAP ITS base URL, e.g. `https://isp.example.com`
   - **Cookies** — paste your browser's `Cookie:` header value from a logged-in SAP WebGUI session (see below)

### Getting your session cookies

1. Log in to SAP WebGUI in your browser.
2. Open DevTools → Network tab.
3. Click any SAP page request and copy the full `Cookie:` header value.
4. Paste it into the app's Settings → Cookies field.

The app needs at minimum `sap-usercontext` and `SAP_SESSIONID_*`. Cookies expire with your browser session, so you'll need to refresh them periodically.

---

## How it works — SAP ITS batch API

The app uses SAP's undocumented WebGUI ITS batch JSON API to drive transaction **IH08** (Equipment List) programmatically, then reads the resulting IE03 (Equipment Detail) screen.

### Request flow

```
GET  /sap/bc/gui/sap/its/webgui?~transaction=IH08
  → extracts ANON session token, moin CSRF token, saplb affinity cookie

POST /sap(TOKEN)/bc/gui/sap/its/webgui/batch/json  (warm-up: ["get":"state/ur"])
  → primes the session for multipart responses

POST /sap(TOKEN)/bc/gui/sap/its/webgui/batch/json  (3-step lookup)
  step 1: post value/wnd[0]/usr/txtSERGE-LOW  (serial number field)
  step 2: post vkey/8/ses[0]                  (F8 = Execute)
  step 3: get  state/ur                       (fetch result screen)
  → response navigates to SAPMIEQ0 (IE03), which contains the equipment record
```

### Gotchas discovered during development

Four non-obvious issues had to be solved to make the batch API work reliably:

**1. First batch call always returns plain XML**

SAP ITS ignores `Accept: multipart/mixed` on the very first batch call to a fresh session and always returns `text/xml`. Subsequent calls in the same session honour the Accept header. Fix: send a warm-up `[{"get":"state/ur"}]` batch call first.

**2. JSON key ordering matters**

SAP ITS reads the **first key** of each batch step JSON object as the operation type. Swift's `JSONEncoder` (and most JSON encoders) sort dictionary keys alphabetically, so `{"content": "...", "post": "..."}` has SAP see `"content"` as the operation — an unknown tag — returning error `-1002`. Fix: build batch JSON manually to guarantee `"post"`/`"get"` appears first, before `"content"` and `"logic"`.

```swift
// Wrong — JSONEncoder output: {"content":"JTG...","logic":"ignore","post":"value/..."}
let step: [String: String] = ["post": "value/...", "content": serial, "logic": "ignore"]
req.httpBody = try JSONEncoder().encode([step])

// Correct — emit post first, then content, then logic
req.httpBody = encodeBatchPayload([step])
```

**3. Forward slashes must not be escaped**

Standard JSON allows `\/` as an escaped forward slash, and some encoders produce it. SAP's ITS JSON parser **rejects** `\/` in batch step path values like `value/wnd[0]/usr/txtSERGE-LOW`. Fix: do not escape `/` in the JSON serialiser.

**4. Field values are in `lsdata` JSON, not HTML `value=` attributes**

SAP IE03 screen elements use SAP's CBS (GuiCTextField) control type. These do not have a standard HTML `value="..."` attribute. Instead, the value is embedded in a `lsdata` JSON attribute:

```html
<input id="M0:46:1:1::0:16" ct="CBS"
  lsdata='{"x":0,"5":"35549176","21":{"value":"35549176","maxlen":18,...}}'>
```

Fix: after looking up `id="..."`, search the following ~800 characters for `"value":"` in the lsdata JSON rather than `value="` as an HTML attribute.

### Required headers for batch POST

| Header | Value |
|---|---|
| `Content-Type` | `application/json;charset=UTF-8` |
| `Accept` | `multipart/mixed` |
| `X-Requested-With` | `XMLHttpRequest` |
| `Sap-Cancel-On-Close` | `true` |
| `moin` | 16-char hex CSRF token from initial GET HTML |
| `Cookie` | `sap-usercontext=...; SAP_SESSIONID_*=...; saplbISP=...` |
| `Origin` | SAP base URL |
| `Referer` | `<base>/sap/bc/gui/sap/its/webgui` |

The `saplbISP` (or `saplb*`) cookie comes from `Set-Cookie` on the initial GET and pins all subsequent requests to the same ITS backend instance that created the session. Without it, batch calls can round-robin to a different server that doesn't have the session state.

### IE03 field element IDs

These IDs were verified against a live ISP system. They may differ on other SAP landscapes.

| Field | Element ID |
|---|---|
| Equipment # | `M0:46:1:1::0:16` |
| Category | `M0:46:1:1::0:49` |
| Description | `M0:46:1:2::0:16` |
| System Status | `M0:46:1:3::0:16` |
| User Status | `M0:46:1:3::0:47` |
| Valid From | `M0:46:1:4::0:16` |
| Object Type | `M0:46:2:3B256:1:1::0:16` |
| Inventory No | `M0:46:2:3B256:1::5:17` |
| User ID | `M0:46:2:3B256:1::4:62` |
| Acquisition Value | `M0:46:2:3B256:2::1:17` |
| Currency | `M0:46:2:3B256:2::1:35` |
| Acquisition Date | `M0:46:2:3B256:2::1:62` |
| Manufacturer | `M0:46:2:3B256:3::1:17` |
| Model | `M0:46:2:3B256:3::2:17` |
| Manufacturer Part No | `M0:46:2:3B256:3::3:17` |
| Serial Number | `M0:46:2:3B256:3::4:17` |

---

## Requirements

- macOS 13 Ventura or later
- Xcode 15+
- An active SAP session (browser cookies)
- Network access to your SAP ITS host
