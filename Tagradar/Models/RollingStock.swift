import Foundation

/// The vehicle type a train runs with, for the few products that use a single fleet.
///
/// Trafikverket's API does not say which vehicles run a train, so this is a hand-curated table.
/// Only add products whose every train runs with one vehicle type; mixed fleets (SJ Regional,
/// Mälartåg, Västtågen, …) must stay unmatched rather than guess.
enum RollingStock: String, CaseIterable, Sendable {
    case x60
    case x61
    case x31k
    case x3
    case x74

    /// Matches on `ProductInformation`, falling back to the operator code for trains without one.
    /// Replacement buses share the train's product (VR runs its buses as "VR Snabbtåg"), so only
    /// rail traffic types match.
    init?(product: String?, operator operatorCode: String?, typeOfTraffic: String?) {
        guard typeOfTraffic.map(Self.railTraffic.contains) ?? true else { return nil }
        switch product {
        case "SL Pendeltåg": self = .x60
        case "Pågatågen": self = .x61
        case "Öresundståg": self = .x31k
        case "VR Snabbtåg": self = .x74
        default:
            guard operatorCode == "ATRAIN" else { return nil }
            self = .x3
        }
    }

    private static let railTraffic: Set<String> = ["Tåg", "Pendeltåg"]

    /// Swedish class designation.
    var designation: String {
        switch self {
        case .x60: "X60"
        case .x61: "X61"
        case .x31k: "X31K"
        case .x3: "X3"
        case .x74: "X74"
        }
    }

    /// Manufacturer and model family.
    var model: String {
        switch self {
        case .x60, .x61: "Alstom Coradia Nordic"
        case .x31k: "Bombardier Contessa"
        case .x3: "Alstom Coradia"
        case .x74: "Stadler FLIRT"
        }
    }
}

/// Operator codes from `TrainAnnouncement.Operator` with a more readable name.
enum OperatorName {
    static func display(_ code: String) -> String {
        names[code] ?? code
    }

    private static let names: [String: String] = [
        // VR bought Arriva Sverige; Trafikverket still reports its trains under the old code.
        "ARRIVA": "VR",
        "ATRAIN": "Arlanda Express",
        "MTRN": "VR",
        "MTRX": "VR",
        "SLL": "SL",
        "SNÄLL": "Snälltåget",
        "TDEV": "Transdev",
        "TÅGAB": "Tågab",
    ]
}
