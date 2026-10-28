import SwiftUI

struct EquipmentTable: View {
    @Environment(AppState.self) private var appState
    @State private var selection: Set<EquipmentRecord.ID> = []

    var body: some View {
        Table(appState.vm.filteredResults, selection: $selection) {
            TableColumn("Serial Number") { r in
                Text(r.serialNumber)
                    .copyMenu(r.serialNumber, label: "Serial Number")
            }
            .width(min: 110, ideal: 130)

            TableColumn("Equipment #") { r in
                Group {
                    if r.equipmentNumber.isEmpty {
                        StatusBadge(status: r.queryStatus)
                    } else {
                        Text(r.equipmentNumber)
                    }
                }
                .copyMenu(r.equipmentNumber, label: "Equipment Number")
            }
            .width(min: 100, ideal: 110)

            TableColumn("Description") { r in
                Text(r.description.isEmpty ? "—" : r.description)
                    .lineLimit(1)
                    .foregroundStyle(r.description.isEmpty ? .tertiary : .primary)
                    .copyMenu(r.description, label: "Description")
            }
            .width(min: 140, ideal: 200)

            TableColumn("User ID") { r in
                Text(r.userId.isEmpty ? "—" : r.userId)
                    .foregroundStyle(r.userId.isEmpty ? .tertiary : .primary)
                    .copyMenu(r.userId, label: "User ID")
            }
            .width(min: 80, ideal: 90)

            TableColumn("Manufacturer") { r in
                Text(r.manufacturer.isEmpty ? "—" : r.manufacturer)
                    .lineLimit(1)
                    .foregroundStyle(r.manufacturer.isEmpty ? .tertiary : .primary)
                    .copyMenu(r.manufacturer, label: "Manufacturer")
            }
            .width(min: 80, ideal: 100)

            TableColumn("Model") { r in
                Text(r.modelNumber.isEmpty ? "—" : r.modelNumber)
                    .lineLimit(1)
                    .foregroundStyle(r.modelNumber.isEmpty ? .tertiary : .primary)
                    .copyMenu(r.modelNumber, label: "Model")
            }
            .width(min: 100, ideal: 140)

            TableColumn("Acquisition Date") { r in
                Text(r.acquisitionDate.isEmpty ? "—" : r.acquisitionDate)
                    .foregroundStyle(r.acquisitionDate.isEmpty ? .tertiary : .primary)
                    .copyMenu(r.acquisitionDate, label: "Acquisition Date")
            }
            .width(min: 80, ideal: 100)

            TableColumn("Value") { r in
                let val = r.acquisitionValue.isEmpty ? "—" : "\(r.acquisitionValue) \(r.currency)"
                Text(val)
                    .foregroundStyle(r.acquisitionValue.isEmpty ? .tertiary : .primary)
                    .copyMenu(val, label: "Acquisition Value")
            }
            .width(min: 80, ideal: 110)

            TableColumn("Status") { r in
                if !r.error.isEmpty {
                    Text(r.error)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                } else {
                    let s = [r.systemStatus, r.userStatus].filter { !$0.isEmpty }.joined(separator: " / ")
                    Text(s.isEmpty ? "—" : s)
                        .foregroundStyle(s.isEmpty ? .tertiary : .primary)
                        .copyMenu(s, label: "Status")
                }
            }
            .width(min: 80, ideal: 100)
        }
        .tableStyle(.inset)
    }
}

// MARK: - Status badge

struct StatusBadge: View {
    let status: EquipmentRecord.QueryStatus

    var body: some View {
        Text(status.rawValue)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var color: Color {
        switch status {
        case .pending:    return .secondary
        case .running:    return .blue
        case .found:      return .green
        case .restricted: return Color(red: 0.8, green: 0.5, blue: 0.0)
        case .notFound:   return .orange
        case .error:      return .red
        }
    }
}

// MARK: - Copy context menu

private struct CopyMenuModifier: ViewModifier {
    let value: String
    let label: String

    func body(content: Content) -> some View {
        content.contextMenu {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Label("Copy \(label)", systemImage: "doc.on.doc")
            }
            .disabled(value.isEmpty)
        }
    }
}

extension View {
    fileprivate func copyMenu(_ value: String, label: String) -> some View {
        modifier(CopyMenuModifier(value: value, label: label))
    }
}
