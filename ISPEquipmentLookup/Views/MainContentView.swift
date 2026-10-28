import SwiftUI
import UniformTypeIdentifiers

struct MainContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        VStack(spacing: 0) {
            ToolbarView()
            Divider()
            SourcePickerView()
            Divider()
            ResultsAreaView()
            Divider()
            StatusBarView()
        }
        .sheet(isPresented: Binding(
            get: { appState.vm.showSettings },
            set: { appState.vm.showSettings = $0 }
        )) {
            SettingsView().environment(appState)
        }
    }
}

// MARK: - Toolbar

struct ToolbarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var vm = appState.vm

        HStack(spacing: 10) {
            Button { vm.showSettings = true } label: {
                Image(systemName: "gear")
            }
            .help("Configure SAP session cookies")

            Divider().frame(height: 20)

            // Search
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter results…", text: $vm.searchText)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 180)
                if !vm.searchText.isEmpty {
                    Button { vm.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.background.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.separator, lineWidth: 1))

            Spacer()

            if vm.errorCount > 0 {
                Label("\(vm.errorCount) error", systemImage: "xmark.circle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
            if vm.notFoundCount > 0 {
                Label("\(vm.notFoundCount) not found", systemImage: "questionmark.circle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }

            Divider().frame(height: 20)

            // Export
            if !appState.vm.results.isEmpty {
                Menu {
                    Button("Export CSV…") { exportFile(format: .csv) }
                    Button("Export JSON…") { exportFile(format: .json) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(vm.isRunning)
            }

            // Run / Cancel
            if vm.isRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { vm.cancel() }.controlSize(.small)
                }
            } else {
                Button {
                    vm.run(settings: appState.settings)
                } label: {
                    Label("Look Up", systemImage: "magnifyingglass")
                }
                .disabled(!appState.settings.isComplete)
                .keyboardShortcut("r", modifiers: .command)
                .help(appState.settings.isComplete ? "Run lookup (⌘R)" : "Configure cookies first (gear icon)")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private enum ExportFormat { case csv, json }

    private func exportFile(format: ExportFormat) {
        let panel = NSSavePanel()
        switch format {
        case .csv:
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = "isp-equipment.csv"
        case .json:
            panel.allowedContentTypes = [UTType.json]
            panel.nameFieldStringValue = "isp-equipment.json"
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let content = format == .csv ? appState.vm.buildCSV() : appState.vm.buildJSON()
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Source Picker

struct SourcePickerView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var vm = appState.vm

        HStack(spacing: 12) {
            Picker("Source", selection: $vm.sourceMode) {
                ForEach(SourceMode.allCases) { mode in
                    Label(mode.rawValue, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)
            .labelsHidden()

            switch vm.sourceMode {
            case .single:
                HStack(spacing: 6) {
                    TextField("Serial number (e.g. JTG2JXJ62Q)", text: $vm.singleSerial)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 220)
                        .onSubmit { vm.run(settings: appState.settings) }
                    Text("or press ⌘R").font(.caption).foregroundStyle(.tertiary)
                }

            case .pasteList:
                HStack(spacing: 6) {
                    Text("One serial per line:").font(.callout).foregroundStyle(.secondary)
                    TextEditor(text: $vm.pasteText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 54)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator, lineWidth: 1))
                }

            case .csvImport:
                HStack(spacing: 8) {
                    Button {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
                        panel.allowsMultipleSelection = false
                        panel.begin { response in
                            guard response == .OK, let url = panel.url else { return }
                            vm.importCSV(url: url)
                        }
                    } label: {
                        Label("Choose File…", systemImage: "doc.text")
                    }
                    if vm.importedCount > 0 {
                        Text("\(vm.importedCount) serials loaded")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

// MARK: - Results area

struct ResultsAreaView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let vm = appState.vm

        if vm.results.isEmpty && !vm.isRunning {
            ContentUnavailableView(
                appState.settings.isComplete ? "No Results" : "Setup Required",
                systemImage: appState.settings.isComplete ? "desktopcomputer" : "gear",
                description: Text(appState.settings.isComplete
                    ? "Enter a serial number and press Look Up (⌘R)."
                    : "Click the gear icon to paste your SAP session cookies.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                if vm.isRunning && !vm.results.isEmpty {
                    GeometryReader { geo in
                        Rectangle().fill(Color.accentColor)
                            .frame(width: geo.size.width * vm.progress)
                            .animation(.linear(duration: 0.15), value: vm.progress)
                    }.frame(height: 2)
                }
                EquipmentTable()
            }
        }
    }
}

// MARK: - Status bar

struct StatusBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let vm = appState.vm
        HStack {
            if !vm.errorMessage.isEmpty {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text(vm.errorMessage).foregroundStyle(.red)
            } else if !vm.statusMessage.isEmpty {
                Text(vm.statusMessage).foregroundStyle(.secondary)
            }
            Spacer()
            if !vm.results.isEmpty {
                Text("\(vm.filteredResults.count) of \(vm.results.count) records")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 14).padding(.vertical, 5)
    }
}
