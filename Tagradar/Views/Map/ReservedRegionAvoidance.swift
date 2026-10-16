import os
import SwiftUI

/// Moves a floating map overlay clear of the screen's reserved regions: the cameras and, when an
/// iPhone Duo is partially folded, the fold. The map itself runs edge to edge and under all of
/// them; only the small glass controls on top of it need to stay readable and tappable.
///
/// The shift is an offset rather than padding, so it never changes layout. The regions are read from
/// a probe behind the overlay rather than from the overlay itself: they are reported in the view's
/// own coordinate space, which an offset moves too, so reading them from the shifted view would
/// move the region along with it and the shift would never settle. The probe stays at the unshifted
/// frame. Before iOS 27.1, and on every device without reserved regions, this does nothing.
private struct ReservedRegionAvoidance: ViewModifier {
    @State private var shift: CGSize = .zero
    private nonisolated static let logger = Logger(subsystem: "se.tagradar.app", category: "ReservedRegion")

    func body(content: Content) -> some View {
        content
            .offset(shift)
            .background {
                Color.clear
                    .onGeometryChange(for: CGSize.self) { proxy in
                        guard #available(iOS 27.1, *) else { return .zero }
                        return Self.shift(for: proxy)
                    } action: { newShift in
                        Self.logger.debug("shift → \(newShift.width), \(newShift.height)")
                        withAnimation(.smooth) { shift = newShift }
                    }
            }
    }

    @available(iOS 27.1, *)
    private nonisolated static func shift(for proxy: GeometryProxy) -> CGSize {
        let global = proxy.frame(in: .global)
        var shift = CGSize.zero
        // Occlusion covers the cameras, each with a margin for interactive content around it — on the
        // inner display that includes the camera at the top of the fold. Division is the fold itself.
        let regions = (proxy.reservedRegions(kind: .occlusion) + proxy.reservedRegions(kind: .division))
            .filter(\.isActive)
        for region in regions {
            let frame = CGRect(origin: .zero, size: proxy.size).offsetBy(dx: shift.width, dy: shift.height)
            guard frame.intersects(region.frame) else { continue }
            // The four ways out of the region, shortest first. A way out that would push the overlay
            // past the top or leading edge of the screen is no way out: the regions sit against those
            // edges, so the shorter move is often the one that slides it off the screen.
            let candidates = [
                CGSize(width: region.frame.maxX - frame.minX, height: 0),
                CGSize(width: region.frame.minX - frame.maxX, height: 0),
                CGSize(width: 0, height: region.frame.maxY - frame.minY),
                CGSize(width: 0, height: region.frame.minY - frame.maxY),
            ]
            let move = candidates
                .filter { global.minX + shift.width + $0.width >= 0 && global.minY + shift.height + $0.height >= 0 }
                .min { abs($0.width) + abs($0.height) < abs($1.width) + abs($1.height) }
            guard let move else { continue }
            shift.width += move.width
            shift.height += move.height
        }
        return shift
    }
}

extension View {
    /// Keeps a floating overlay out from under the cameras and the fold; see `ReservedRegionAvoidance`.
    func avoidingReservedRegions() -> some View {
        modifier(ReservedRegionAvoidance())
    }
}
