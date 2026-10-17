import CoreGraphics
@testable import Tagradar
import Testing

/// The off-screen train pill sits in a fixed corner and only its arrow follows the train (#70).
@Suite("SelectedTrainIndicator")
struct SelectedTrainIndicatorTests {
    /// iPhone 17 Pro Max, card at its middle height: the uncovered map above it, the controls'
    /// column taken off the trailing edge. The arrow then sits at (16 + 18, 420 - 18) = (34, 402).
    private let bounds = CGRect(x: 0, y: 120, width: 376, height: 300)

    @Test("The arrow points from where it sits to the train", arguments: [
        (CGPoint(x: 34, y: -1000), 0.0), // straight up
        (CGPoint(x: 2000, y: 402), 90.0), // to the right
        (CGPoint(x: 34, y: 2000), 180.0), // straight down
        (CGPoint(x: -2000, y: 402), -90.0), // to the left
        (CGPoint(x: 434, y: 2), 45.0), // up and to the right
    ])
    func arrowFromCorner(target: CGPoint, degrees: Double) {
        let angle = SelectedTrainIndicator.arrowAngle(bounds: bounds, target: target)
        #expect(abs(angle.degrees - degrees) < 0.001)
    }

    @Test("The arrow is aimed from the corner, not the middle of the map")
    func notFromTheMiddle() {
        // Straight above the middle of the map (188, 270): from the corner that is up and right.
        let angle = SelectedTrainIndicator.arrowAngle(bounds: bounds, target: CGPoint(x: 188, y: -1000))
        #expect(angle.degrees > 5 && angle.degrees < 15)
    }

    @Test("Clearance lifts the arrow with the pill")
    func clearanceLiftsArrow() {
        // Level with the lifted arrow at y = 420 - 56 - 18 = 346, the train is due right only with it.
        let target = CGPoint(x: 2000, y: 346)
        let lifted = SelectedTrainIndicator.arrowAngle(bounds: bounds, bottomClearance: 56, target: target)
        let unlifted = SelectedTrainIndicator.arrowAngle(bounds: bounds, target: target)
        #expect(abs(lifted.degrees - 90) < 0.001)
        #expect(abs(unlifted.degrees - 90) > 1)
    }

    @Test("The pill appears from its own corner")
    func transitionAnchor() {
        // The transition scales the frame from the map's origin to the bottom-trailing corner of
        // `bounds`, (376, 420); the pill's corner is at (16, 420), or (16, 364) lifted by 56.
        let corner = SelectedTrainIndicator.pillCorner(bounds: bounds)
        #expect(abs(corner.x - 16.0 / 376) < 0.0001)
        #expect(corner.y == 1)
        let lifted = SelectedTrainIndicator.pillCorner(bounds: bounds, bottomClearance: 56)
        #expect(abs(lifted.y - 364.0 / 420) < 0.0001)
    }

    @Test("On iPad the pill clears the home indicator and the Apple Maps attribution")
    func regularBottomClearance() {
        #expect(MapLayout.regularIndicatorBottomClearance(windowBottomInset: 20) == 56)
        #expect(MapLayout.regularIndicatorBottomClearance(windowBottomInset: 0) == 36)
    }
}
