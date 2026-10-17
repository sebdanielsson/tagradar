import CoreGraphics
@testable import Tagradar
import Testing

/// The off-screen train pill sits in a fixed corner and only its arrow follows the train (#70).
@Suite("SelectedTrainIndicator")
struct SelectedTrainIndicatorTests {
    // iPhone 17 Pro Max, card at its middle height: the uncovered map above it, the controls'
    // column taken off the trailing edge.
    private let bounds = CGRect(x: 0, y: 120, width: 376, height: 300)
    private let pill = CGSize(width: 110, height: 36)

    @Test("The pill sits in the bottom-leading corner, wherever the train is", arguments: [
        CGPoint(x: -500, y: 200), CGPoint(x: 900, y: -300), CGPoint(x: 188, y: 2000), CGPoint(x: 188, y: -2000),
    ])
    func fixedCorner(target: CGPoint) {
        let layout = SelectedTrainIndicator.layout(bounds: bounds, target: target, size: pill)
        #expect(layout.position.x == bounds.minX + SelectedTrainIndicator.leadingMargin + pill.width / 2)
        #expect(layout.position.y == bounds.maxY - SelectedTrainIndicator.bottomMargin - pill.height / 2)
    }

    @Test("The arrow points from the pill to the train", arguments: [
        (CGPoint(x: 71, y: -1000), 0.0), // straight up
        (CGPoint(x: 2000, y: 402), 90.0), // to the right
        (CGPoint(x: 71, y: 2000), 180.0), // straight down
        (CGPoint(x: -2000, y: 402), -90.0), // to the left
    ])
    func arrowFromPill(target: CGPoint, degrees: Double) {
        // The pill's centre is (16 + 55, 420 - 18) = (71, 402).
        let layout = SelectedTrainIndicator.layout(bounds: bounds, target: target, size: pill)
        #expect(abs(layout.angle.degrees - degrees) < 0.001)
    }

    @Test("Before the pill has been measured it still lands in the corner")
    func unmeasuredPill() {
        let layout = SelectedTrainIndicator.layout(bounds: bounds, target: CGPoint(x: 900, y: 0), size: .zero)
        #expect(layout.position == CGPoint(x: SelectedTrainIndicator.leadingMargin, y: bounds.maxY))
    }

    @Test("On iPad the pill clears the home indicator and the Apple Maps attribution")
    func regularBottomInset() {
        #expect(MapLayout.regularIndicatorBottomInset(windowBottomInset: 20) == 20 + MapLayout.mapAttributionHeight)
        #expect(MapLayout.regularIndicatorBottomInset(windowBottomInset: 0) == MapLayout.mapAttributionHeight)
    }
}
