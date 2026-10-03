@testable import Tagradar
import Testing

@Suite("Rolling stock")
struct RollingStockTests {
    @Test func matchesSingleFleetProducts() {
        #expect(RollingStock(product: "SL Pendeltåg", operator: "SLL", typeOfTraffic: "Tåg") == .x60)
        #expect(RollingStock(product: "Pågatågen", operator: "ARRIVA", typeOfTraffic: "Tåg") == .x61)
        #expect(RollingStock(product: "Öresundståg", operator: "ARRIVA", typeOfTraffic: "Tåg") == .x31k)
        #expect(RollingStock(product: "VR Snabbtåg", operator: "MTRX", typeOfTraffic: "Tåg") == .x74)
        #expect(RollingStock(product: nil, operator: "ATRAIN", typeOfTraffic: "Tåg") == .x3)
    }

    @Test func leavesMixedFleetsUnmatched() {
        #expect(RollingStock(product: "SJ Regional", operator: "SJ", typeOfTraffic: "Tåg") == nil)
        #expect(RollingStock(product: "Mälartåg", operator: "TDEV", typeOfTraffic: "Tåg") == nil)
        #expect(RollingStock(product: nil, operator: nil, typeOfTraffic: "Tåg") == nil)
    }

    @Test func skipsReplacementBuses() {
        #expect(RollingStock(product: "VR Snabbtåg", operator: "MTRN", typeOfTraffic: "Buss") == nil)
        #expect(RollingStock(product: "SL Pendeltåg", operator: "SLL", typeOfTraffic: "Pendeltåg") == .x60)
        #expect(RollingStock(product: "Pågatågen", operator: "ARRIVA", typeOfTraffic: nil) == .x61)
    }

    @Test func readableOperatorNames() {
        #expect(OperatorName.display("TDEV") == "Transdev")
        #expect(OperatorName.display("SJ") == "SJ")
    }
}
