import Foundation

// Simplified: the key result is the equipment number; other fields are bonus context.
struct EquipmentRecord: Identifiable, Codable {
    var id: String { serialNumber }

    var serialNumber: String        // the input
    var equipmentNumber: String     // e.g. 35549176 — the primary result
    var description: String         // short description
    var userId: String              // assigned user (Size/dimension field)
    var manufacturer: String
    var modelNumber: String
    var acquisitionDate: String
    var acquisitionValue: String
    var currency: String
    var inventoryNo: String
    var systemStatus: String
    var userStatus: String
    var objectType: String
    var manufacturerPartNo: String
    var validFrom: String
    var category: String

    var queryStatus: QueryStatus = .pending
    var error: String = ""

    enum QueryStatus: String, Codable {
        case pending  = "Pending"
        case running  = "Running"
        case found    = "Found"
        case notFound = "Not Found"
        case error    = "Error"
    }

    static func stub(serialNumber: String) -> EquipmentRecord {
        EquipmentRecord(
            serialNumber: serialNumber, equipmentNumber: "", description: "",
            userId: "", manufacturer: "", modelNumber: "", acquisitionDate: "",
            acquisitionValue: "", currency: "", inventoryNo: "", systemStatus: "",
            userStatus: "", objectType: "", manufacturerPartNo: "", validFrom: "",
            category: "", queryStatus: .pending)
    }
}
