import Foundation
import UniformTypeIdentifiers

enum SourceMode: String, CaseIterable, Identifiable {
    case single    = "Single Serial"
    case pasteList = "Paste List"
    case csvImport = "Import CSV"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .single:    return "magnifyingglass"
        case .pasteList: return "list.bullet"
        case .csvImport: return "doc.text"
        }
    }
}

@MainActor
@Observable
class LookupViewModel {

    // MARK: - Input state
    var sourceMode: SourceMode = .single
    var singleSerial: String = ""
    var pasteText: String = ""

    // MARK: - Run state
    var results: [EquipmentRecord] = []
    var isRunning: Bool = false
    var progress: Double = 0
    var statusMessage: String = ""
    var errorMessage: String = ""
    var searchText: String = ""
    var showSettings: Bool = false

    private var runTask: Task<Void, Never>?

    // MARK: - Computed

    var filteredResults: [EquipmentRecord] {
        guard !searchText.isEmpty else { return results }
        let q = searchText.lowercased()
        return results.filter {
            $0.serialNumber.lowercased().contains(q) ||
            $0.equipmentNumber.lowercased().contains(q) ||
            $0.description.lowercased().contains(q) ||
            $0.userId.lowercased().contains(q) ||
            $0.manufacturer.lowercased().contains(q) ||
            $0.modelNumber.lowercased().contains(q)
        }
    }

    var errorCount: Int { results.filter { $0.queryStatus == .error }.count }
    var notFoundCount: Int { results.filter { $0.queryStatus == .notFound }.count }

    // MARK: - Run / Cancel

    func run(settings: SettingsStore) {
        guard !isRunning else { return }
        runTask = Task { await runAsync(settings: settings) }
    }

    // Thrown when cookie refresh fails — signals the run loop to abort entirely.
    private struct SessionExpiredError: Error {
        let message: String
    }

    // Executes `body`. If it throws an HTTP 400 or 500, tries once to refresh cookies
    // from Chrome and retries. If refresh fails, throws SessionExpiredError to abort the run.
    private func withCookieRefresh<T>(settings: SettingsStore,
                                      _ body: @Sendable () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch ISPEquipmentService.ServiceError.httpError(let code, _) where code == 400 || code == 500 {
            let fresh = try? ChromeCookieReader.readISPCookies()
            guard let fresh else {
                throw SessionExpiredError(message: "Session expired — refresh cookies in Settings (gear icon)")
            }
            settings.ispCookies = fresh
            statusMessage = "Cookies refreshed — retrying…"
            return try await body()
        }
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
        statusMessage = "Cancelled."
    }

    private func runAsync(settings: SettingsStore) async {
        isRunning = true
        errorMessage = ""
        progress = 0

        let serials = collectSerials()
        guard !serials.isEmpty else {
            errorMessage = "No serial numbers to look up."
            isRunning = false
            return
        }

        // Populate stubs immediately so the table shows rows
        results = serials.map { EquipmentRecord.stub(serialNumber: $0) }
        statusMessage = "Looking up \(serials.count) serial\(serials.count == 1 ? "" : "s")…"

        let batchSize = max(1, settings.batchSize)
        let concurrency = max(1, settings.concurrency)
        var completed = 0

        var fatalError: String? = nil

        if settings.fetchFullDetail {
            // Full detail: use the original single-serial lookup (IE03 detail per record).
            // Each serial gets its own isolated session — correct and already battle-tested.
            await withThrowingTaskGroup(of: (Int, EquipmentRecord).self) { group in
                var inFlight = 0
                var serialIndex = 0

                func addNext() {
                    guard serialIndex < serials.count, inFlight < concurrency else { return }
                    let idx = serialIndex
                    let sn  = serials[idx]
                    serialIndex += 1
                    inFlight += 1
                    group.addTask {
                        if Task.isCancelled {
                            var r = EquipmentRecord.stub(serialNumber: sn)
                            r.queryStatus = .error; r.error = "Cancelled"
                            return (idx, r)
                        }
                        let taskSession = URLSession(configuration: .ephemeral)
                        return try await self.withCookieRefresh(settings: settings) {
                            do {
                                let sessionInfo = try await ISPEquipmentService.acquireToken(
                                    settings: settings, session: taskSession)
                                return (idx, try await ISPEquipmentService.lookup(
                                    serialNumber: sn, sessionInfo: sessionInfo,
                                    settings: settings, session: taskSession))
                            } catch ISPEquipmentService.ServiceError.notFound {
                                var r = EquipmentRecord.stub(serialNumber: sn)
                                r.equipmentNumber = "i8pi8pi8p"; r.queryStatus = .notFound
                                return (idx, r)
                            } catch ISPEquipmentService.ServiceError.restricted(let equip) {
                                var r = EquipmentRecord.stub(serialNumber: sn)
                                r.equipmentNumber = equip; r.queryStatus = .restricted
                                r.error = "Authorization restricted"
                                return (idx, r)
                            } catch let e as SessionExpiredError {
                                throw e  // propagate to abort the run
                            } catch {
                                var r = EquipmentRecord.stub(serialNumber: sn)
                                r.queryStatus = .error; r.error = error.localizedDescription
                                return (idx, r)
                            }
                        }
                    }
                }

                for _ in 0..<concurrency { addNext() }
                do {
                    for try await (idx, record) in group {
                        if Task.isCancelled { break }
                        results[idx] = record
                        completed += 1; inFlight -= 1
                        progress = Double(completed) / Double(serials.count)
                        statusMessage = "Done \(completed)/\(serials.count)"
                        addNext()
                    }
                } catch let e as SessionExpiredError {
                    group.cancelAll()
                    fatalError = e.message
                } catch {}
            }
        } else {
            // List only: batch mode — 8 serials per IH08 round-trip, fast.
            let chunks: [(startIdx: Int, serials: [String])] = stride(from: 0, to: serials.count, by: batchSize).map { start in
                let end = min(start + batchSize, serials.count)
                return (startIdx: start, serials: Array(serials[start..<end]))
            }

            await withThrowingTaskGroup(of: [(Int, EquipmentRecord)].self) { group in
                var inFlight = 0
                var chunkIndex = 0

                func addNextChunk() {
                    guard chunkIndex < chunks.count, inFlight < concurrency else { return }
                    let chunk = chunks[chunkIndex]
                    chunkIndex += 1; inFlight += 1
                    group.addTask {
                        if Task.isCancelled {
                            return chunk.serials.enumerated().map { (i, sn) in
                                var r = EquipmentRecord.stub(serialNumber: sn)
                                r.queryStatus = .error; r.error = "Cancelled"
                                return (chunk.startIdx + i, r)
                            }
                        }
                        let taskSession = URLSession(configuration: .ephemeral)
                        return try await self.withCookieRefresh(settings: settings) {
                            do {
                                let sessionInfo = try await ISPEquipmentService.acquireToken(
                                    settings: settings, session: taskSession)
                                let records = try await ISPEquipmentService.batchLookup(
                                    serialNumbers: chunk.serials, sessionInfo: sessionInfo,
                                    settings: settings, session: taskSession)
                                return records.enumerated().map { (i, r) in (chunk.startIdx + i, r) }
                            } catch let e as SessionExpiredError {
                                throw e  // propagate to abort the run
                            } catch {
                                return chunk.serials.enumerated().map { (i, sn) in
                                    var r = EquipmentRecord.stub(serialNumber: sn)
                                    r.queryStatus = .error; r.error = error.localizedDescription
                                    return (chunk.startIdx + i, r)
                                }
                            }
                        }
                    }
                }

                for _ in 0..<concurrency { addNextChunk() }
                do {
                    for try await pairs in group {
                        if Task.isCancelled { break }
                        for (idx, record) in pairs { results[idx] = record }
                        completed += pairs.count; inFlight -= 1
                        progress = Double(completed) / Double(serials.count)
                        statusMessage = "Done \(completed)/\(serials.count)"
                        addNextChunk()
                    }
                } catch let e as SessionExpiredError {
                    group.cancelAll()
                    fatalError = e.message
                } catch {}
            }
        }

        if let msg = fatalError {
            errorMessage = msg
            statusMessage = "Stopped — \(completed) of \(serials.count) completed before session expired"
            progress  = Double(completed) / Double(serials.count)
            isRunning = false
            return
        }

        let foundCount  = results.filter { $0.queryStatus == .found }.count
        let restrictCount = results.filter { $0.queryStatus == .restricted }.count
        let errCount    = results.filter { $0.queryStatus == .error }.count
        let nfCount     = results.filter { $0.queryStatus == .notFound }.count
        var parts = ["Found: \(foundCount + restrictCount)"]
        if restrictCount > 0 { parts.append("Restricted: \(restrictCount)") }
        parts.append(contentsOf: ["Not found: \(nfCount)", "Errors: \(errCount)"])
        statusMessage = "Complete — " + parts.joined(separator: "  ")
        progress  = 1
        isRunning = false
    }

    // MARK: - Serial collection

    private func collectSerials() -> [String] {
        switch sourceMode {
        case .single:
            let sn = singleSerial.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return sn.isEmpty ? [] : [sn]
        case .pasteList:
            return pasteText
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
                .filter { !$0.isEmpty }
        case .csvImport:
            return importedSerials
        }
    }

    // MARK: - CSV import

    private(set) var importedSerials: [String] = []
    private(set) var importedCount: Int = 0

    func importCSV(url: URL, settings: SettingsStore? = nil) {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            errorMessage = "Could not read file."; return
        }
        let lines = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { errorMessage = "File is empty."; return }

        // Try to find a serial number column; if not, treat each line as a raw serial
        let firstLine = lines[0]
        if firstLine.lowercased().contains("serial") {
            // Has a header row — find the column index
            let headers = parseCSVLine(firstLine).map { $0.lowercased() }
            let snIdx = headers.firstIndex(where: {
                $0.contains("serial") || $0 == "sn"
            }) ?? 0
            importedSerials = lines.dropFirst().compactMap { line -> String? in
                let cols = parseCSVLine(line)
                guard snIdx < cols.count else { return nil }
                let sn = cols[snIdx].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                return sn.isEmpty ? nil : sn
            }
        } else {
            // No header — each line is a serial (or first column of CSV)
            importedSerials = lines.map { line -> String in
                let first = parseCSVLine(line).first ?? line
                return first.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            }.filter { !$0.isEmpty }
        }

        importedCount = importedSerials.count
        statusMessage  = "Imported \(importedCount) serial\(importedCount == 1 ? "" : "s") from file."
        sourceMode     = .csvImport
        if let settings = settings {
            run(settings: settings)
        }
    }

    private func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        for ch in line {
            if ch == "\"" { inQuotes.toggle() }
            else if ch == "," && !inQuotes { fields.append(current); current = "" }
            else { current.append(ch) }
        }
        fields.append(current)
        return fields
    }

    // MARK: - Export CSV

    func buildCSV() -> String {
        let headers = [
            "Serial Number", "Equipment Number", "Description",
            "System Status", "User Status", "Object Type",
            "Inventory No.", "User ID", "Acquisition Value", "Currency",
            "Acquisition Date", "Manufacturer", "Model Number",
            "Manufacturer Part No.", "Valid From",
            "Category", "Query Status", "Error"
        ]
        var lines = [headers.map { "\"\($0)\"" }.joined(separator: ",")]
        for r in results {
            let row: [String] = [
                r.serialNumber, r.equipmentNumber, r.description,
                r.systemStatus, r.userStatus, r.objectType,
                r.inventoryNo, r.userId, r.acquisitionValue, r.currency,
                r.acquisitionDate, r.manufacturer, r.modelNumber,
                r.manufacturerPartNo, r.validFrom,
                r.category, r.queryStatus.rawValue, r.error
            ]
            lines.append(row.map { "\"\($0)\"" }.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    func buildJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(results),
              let str  = String(data: data, encoding: .utf8)
        else { return "[]" }
        return str
    }
}
