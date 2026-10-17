import CoreGraphics

/// The layout rules `MapScreen` applies to its chrome, as plain functions of the measured geometry so
/// they can be tested. Most exist for the iPhone Duo, whose poses cannot be driven from XCUITest
/// (`XCUIDevice` rotates but cannot fold), so the numbers measured in its simulator are the tests.
enum MapLayout {
    // MARK: Regular layout columns

    /// The sidebar's ideal width, `navigationSplitViewColumnWidth`'s `ideal`.
    static let sidebarWidth: CGFloat = 360
    /// The inspector's ideal width, `inspectorColumnWidth`'s `ideal`.
    static let inspectorWidth: CGFloat = 400
    /// Narrowest the map may get beside the sidebar and the inspector before the sidebar steps aside.
    static let minimumMapWidth: CGFloat = 360

    /// Whether the regular layout shows its sidebar: only in a landscape window with room for it, the
    /// inspector while something is selected, and `minimumMapWidth` of map. Portrait never does, the
    /// way Mail does it. On an iPhone Duo's inner display in landscape (about 950 pt wide) the sidebar
    /// and the inspector together left the map a sliver about 100 pt wide, so there the sidebar steps
    /// aside while a train or station is open. iPads in landscape are wide enough for all three.
    static func showsSidebar(windowSize: CGSize, inspectorOpen: Bool) -> Bool {
        let needed = sidebarWidth + (inspectorOpen ? inspectorWidth : 0) + minimumMapWidth
        return windowSize.width > windowSize.height && windowSize.width >= needed
    }

    // MARK: Map chrome

    /// Space above the status pill and the buttons beside it. Under a status bar a few points are
    /// enough. Without one along the top (an iPhone Duo in landscape, whose status bar runs down the
    /// side) the row would sit 4 pt from the screen's edge, tucked into its rounded corner, so it
    /// gets the same margin as from the leading edge instead.
    static func topChromeTopPadding(windowTopInset: CGFloat) -> CGFloat {
        windowTopInset > 0 ? 4 : 16
    }

    /// Bottom padding that keeps the iPhone map controls just above the card, in the bottom-trailing
    /// corner. Measured from where the card's top actually is (`cardTop`, in the same coordinate
    /// space as `containerMaxY`) rather than worked out from the detent, because what a detent comes
    /// to depends on the screen: on an iPhone Duo's outer display in landscape the middle one is no
    /// taller than the search bar, and a fraction of the screen put the controls halfway up the map.
    /// At the full height the card covers the map, and the controls go off-screen with it.
    static func controlsBottomPadding(
        containerHeight: CGFloat,
        containerMaxY: CGFloat,
        cardTop: CGFloat?,
        cardIsFull: Bool,
        collapsedCardHeight: CGFloat
    ) -> CGFloat {
        if cardIsFull {
            return containerHeight + 200
        }
        guard let cardTop else { return collapsedCardHeight + 16 }
        return max(16, containerMaxY - cardTop + 16)
    }

    // MARK: Reserved regions

    /// How far to move an overlay of `size`, whose top-leading corner sits at `origin` in screen
    /// coordinates, so it overlaps none of `regions` (in its own coordinate space, as
    /// `GeometryProxy.reservedRegions` reports them). Each region it overlaps is left by the shortest
    /// of the four ways out that keeps the overlay below the top and right of the leading edge of the
    /// screen, and clear of every other region: the
    /// regions sit against the top and leading edges, so the shortest move is often the one that
    /// would slide the overlay off the screen, and on the inner display one region's way out can be
    /// another's inside. A region with no such way out is left alone.
    static func reservedRegionShift(size: CGSize, origin: CGPoint, regions: [CGRect]) -> CGSize {
        var shift = CGSize.zero
        for region in regions {
            let frame = CGRect(origin: .zero, size: size).offsetBy(dx: shift.width, dy: shift.height)
            guard frame.intersects(region) else { continue }
            let candidates = [
                CGSize(width: region.maxX - frame.minX, height: 0),
                CGSize(width: region.minX - frame.maxX, height: 0),
                CGSize(width: 0, height: region.maxY - frame.minY),
                CGSize(width: 0, height: region.minY - frame.maxY),
            ]
            let move = candidates
                .filter { move in
                    let moved = frame.offsetBy(dx: move.width, dy: move.height)
                    return origin.x + moved.minX >= 0 && origin.y + moved.minY >= 0
                        && !regions.contains { $0.intersects(moved) }
                }
                .min { abs($0.width) + abs($0.height) < abs($1.width) + abs($1.height) }
            guard let move else { continue }
            shift.width += move.width
            shift.height += move.height
        }
        return shift
    }
}
