import SwiftUI

/// Which toolbar items give way first when the bar runs out of room.
enum ToolbarOverflow {
    /// The actions people come to this screen for; they leave the bar last.
    case keepVisible
    /// Secondary actions; they move to the overflow menu first.
    case overflowFirst
}

extension ToolbarContent {
    /// Sets the item's `visibilityPriority` on iOS 27 and later. It matters most on iPhone Duo: on
    /// the outer display, and on the inner display in landscape, the bars run down the side of the
    /// screen and items overflow from the bottom up, so without a priority the order alone decides
    /// what disappears. Earlier systems keep the default.
    @ToolbarContentBuilder
    func toolbarOverflow(_ overflow: ToolbarOverflow) -> some ToolbarContent {
        if #available(iOS 27, *) {
            visibilityPriority(overflow == .keepVisible ? .high : .low)
        } else {
            self
        }
    }
}
