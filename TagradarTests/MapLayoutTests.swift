import CoreGraphics
@testable import Tagradar
import Testing

/// The iPhone Duo's poses cannot be driven from XCUITest (`XCUIDevice` rotates but cannot fold), so
/// its layout rules are tested here with the window sizes and reserved regions measured in its
/// simulator. Sizes are in points.
@Suite("MapLayout")
struct MapLayoutTests {
    // Measured in the iOS 27 simulators.
    private let duoInnerLandscape = CGSize(width: 951, height: 669)
    private let duoInnerPortrait = CGSize(width: 669, height: 951)
    private let iPad13Portrait = CGSize(width: 1032, height: 1376)

    // MARK: Sidebar

    @Test("iPhone Duo inner display in landscape: sidebar beside the map while nothing is selected")
    func duoLandscapeShowsSidebarWithoutInspector() {
        #expect(MapLayout.showsSidebar(windowSize: duoInnerLandscape, inspectorOpen: false))
    }

    @Test("iPhone Duo inner display in landscape: sidebar steps aside for the inspector, keeping the map usable")
    func duoLandscapeHidesSidebarForInspector() {
        #expect(!MapLayout.showsSidebar(windowSize: duoInnerLandscape, inspectorOpen: true))
    }

    @Test("iPads in landscape keep all three columns", arguments: [CGSize(width: 1376, height: 1032), CGSize(width: 1210, height: 834)])
    func iPadLandscapeKeepsAllColumns(size: CGSize) {
        #expect(MapLayout.showsSidebar(windowSize: size, inspectorOpen: true))
        #expect(MapLayout.showsSidebar(windowSize: size, inspectorOpen: false))
    }

    @Test("Portrait never shows the sidebar", arguments: [false, true])
    func portraitHidesSidebar(inspectorOpen: Bool) {
        #expect(!MapLayout.showsSidebar(windowSize: duoInnerPortrait, inspectorOpen: inspectorOpen))
        #expect(!MapLayout.showsSidebar(windowSize: iPad13Portrait, inspectorOpen: inspectorOpen))
    }

    @Test("The sidebar rule uses the columns' ideal widths, so the map always keeps its minimum")
    func sidebarLeavesMinimumMap() {
        let tight = CGSize(
            width: MapLayout.sidebarWidth + MapLayout.inspectorWidth + MapLayout.minimumMapWidth,
            height: 600
        )
        #expect(MapLayout.showsSidebar(windowSize: tight, inspectorOpen: true))
        #expect(!MapLayout.showsSidebar(windowSize: CGSize(width: tight.width - 1, height: 600), inspectorOpen: true))
    }

    // MARK: Top chrome

    @Test("Under a status bar the top row keeps a few points")
    func topPaddingUnderStatusBar() {
        #expect(MapLayout.topChromeTopPadding(windowTopInset: 62) == 4)
    }

    @Test("Without a status bar along the top (Duo in landscape) the top row clears the screen corner")
    func topPaddingWithoutStatusBar() {
        #expect(MapLayout.topChromeTopPadding(windowTopInset: 0) == 16)
    }

    // MARK: Map controls

    @Test("Controls sit just above the card's measured top edge")
    func controlsFollowCardTop() {
        // iPhone Duo outer display in landscape: the middle detent is no taller than the search bar.
        let padding = MapLayout.controlsBottomPadding(
            containerHeight: 432, containerMaxY: 432, cardTop: 356, cardIsFull: false, collapsedCardHeight: 76
        )
        #expect(padding == 92)
    }

    @Test("Before the card has been measured the controls clear its collapsed height")
    func controlsBeforeCardMeasured() {
        let padding = MapLayout.controlsBottomPadding(
            containerHeight: 900, containerMaxY: 956, cardTop: nil, cardIsFull: false, collapsedCardHeight: 76
        )
        #expect(padding == 92)
    }

    @Test("A card at its full height takes the controls off-screen")
    func controlsLeaveWithFullCard() {
        let padding = MapLayout.controlsBottomPadding(
            containerHeight: 900, containerMaxY: 956, cardTop: 60, cardIsFull: true, collapsedCardHeight: 76
        )
        #expect(padding > 900)
    }

    @Test("A card measured below the map (while it animates away) keeps the controls on the map")
    func controlsNeverBelowMap() {
        let padding = MapLayout.controlsBottomPadding(
            containerHeight: 900, containerMaxY: 956, cardTop: 1000, cardIsFull: false, collapsedCardHeight: 76
        )
        #expect(padding == 16)
    }

    // MARK: Reserved regions

    private let pill = CGSize(width: 117, height: 26)

    @Test("No reserved regions, no shift")
    func noRegions() {
        #expect(MapLayout.reservedRegionShift(size: pill, origin: CGPoint(x: 16, y: 16), regions: []) == .zero)
    }

    @Test("A region that does not overlap the overlay is ignored")
    func regionElsewhere() {
        // The outer camera with its margin, at the top-trailing corner, seen from the status pill.
        let camera = CGRect(x: 366, y: -4, width: 84, height: 174)
        #expect(MapLayout.reservedRegionShift(size: pill, origin: CGPoint(x: 16, y: 4), regions: [camera]) == .zero)
    }

    @Test("An overlay leaves a region by the shortest way out")
    func shortestWayOut() {
        // The inner camera at the top of the fold, partly under the pill: one point to its right.
        let camera = CGRect(x: -100, y: -40, width: 101, height: 300)
        let shift = MapLayout.reservedRegionShift(size: pill, origin: CGPoint(x: 400, y: 16), regions: [camera])
        #expect(shift == CGSize(width: 1, height: 0))
    }

    @Test("The shortest way out is skipped when it would slide the overlay off the top of the screen")
    func neverOffTheTop() {
        // Measured on the Duo: a 124 × 84 pt camera margin over a pill 4 pt from the top. Up by 30
        // is shortest, and off the screen.
        let camera = CGRect(x: -16, y: -4, width: 124, height: 84)
        let shift = MapLayout.reservedRegionShift(size: pill, origin: CGPoint(x: 16, y: 4), regions: [camera])
        #expect(shift == CGSize(width: 0, height: 80))
    }

    @Test("The shortest way out is skipped when it would slide the overlay off the leading edge")
    func neverOffTheLeadingEdge() {
        // Left by 17 is shortest but would put the pill at x = -12; up by 126 is the next best.
        let region = CGRect(x: 100, y: -100, width: 300, height: 300)
        let shift = MapLayout.reservedRegionShift(size: pill, origin: CGPoint(x: 5, y: 300), regions: [region])
        #expect(shift == CGSize(width: 0, height: -126))
    }

    @Test("A way out that runs into another region is not taken")
    func neverIntoAnotherRegion() {
        // Right by 50 would leave the first region and land in the second; up would leave the screen.
        let first = CGRect(x: 0, y: -100, width: 50, height: 226)
        let second = CGRect(x: 150, y: -100, width: 50, height: 226)
        let shift = MapLayout.reservedRegionShift(size: pill, origin: CGPoint(x: 100, y: 100), regions: [first, second])
        #expect(shift == CGSize(width: 0, height: 126))
    }
}
