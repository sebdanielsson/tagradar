import SwiftUI

/// Simplified side view of a vehicle type with its designation, drawn in code so no third-party
/// artwork (and no licence) is involved. Proportions, door layout and livery colours follow
/// reference photos; logos and lettering are left out.
struct RollingStockView: View {
    let stock: RollingStock

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RollingStockDrawing(profile: stock.profile)
                .frame(height: 50)
                .accessibilityHidden(true)
            HStack(spacing: 6) {
                Text(stock.designation).font(.subheadline.weight(.semibold))
                Text(stock.model).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Train type: \(stock.designation), \(stock.model)"))
    }
}

// MARK: - Profiles

/// The shape and livery of one vehicle type, in drawing units: the body side runs from the roof
/// at y = 0 to `RollingStockProfile.bodyBottom`, the rail sits at y = 1 and x = 0 is the nose tip.
struct RollingStockProfile {
    static let bodyBottom = 0.82

    enum Nose {
        /// Long rounded slope with a wrap-around visor (Coradia Nordic).
        case visor
        /// Near-vertical front with a gangway door, framed in black (Contessa).
        case gangway
        /// Long wedge sloping from far back (X3).
        case wedge
        /// Tall rounded bubble over a stepped buffer beam (FLIRT).
        case bubble
    }

    struct Car {
        var length: Double
        /// Door leaves as fractions of the car length from its front end.
        var doors: [ClosedRange<Double>]
        /// Conventional bogie centres as fractions of the car length.
        var bogies: [Double]
        /// Side windows are laid out in the gaps between doors from here on (fraction of length).
        var windowsFrom: Double = 0.03
        var windowsTo: Double = 0.97
    }

    struct Livery {
        var body: Color
        var trailerBody: Color?
        var door: Color
        var front: Color
        var accent: Color?
        var skirt: Color?
        /// Dark panel behind the windows, for trains whose windows read as one band.
        var windowBand: Color?
    }

    var nose: Nose
    var cab: Car
    var trailer: Car
    /// Shared bogies under every car joint.
    var jacobsBogies: Bool
    var windowWidth: Double
    var windowPitch: Double
    var windowTop = 0.2
    var windowBottom = 0.46
    var doorTop = 0.12
    var doorBottom = 0.78
    /// Double doors have a centre split and a window in each leaf.
    var doubleDoors: Bool
    var livery: Livery
    /// Pantograph position along the trailer, as a fraction of its length.
    var pantograph: Double
}

extension RollingStock {
    var profile: RollingStockProfile {
        switch self {
        case .x60, .x61:
            RollingStockProfile(
                nose: .visor,
                cab: .init(length: 3.9, doors: [0.25 ... 0.33, 0.86 ... 0.94], bogies: [0.13], windowsFrom: 0.2),
                trailer: .init(length: 3.4, doors: [0.08 ... 0.17, 0.82 ... 0.91], bogies: []),
                jacobsBogies: true,
                windowWidth: 0.25,
                windowPitch: 0.33,
                windowTop: 0.18,
                doubleDoors: true,
                livery: self == .x60
                    ? .init(
                        body: Color(rgb: 0xE4E7EA),
                        door: Color(rgb: 0x2F6FBF),
                        front: Color(rgb: 0x2F6FBF),
                        accent: Color(rgb: 0x2F6FBF)
                    )
                    : .init(body: Color(rgb: 0x5A5FD6), door: Color(rgb: 0x5A5FD6), front: Color(rgb: 0x8E91EC)),
                pantograph: 0.55
            )
        case .x31k:
            RollingStockProfile(
                nose: .gangway,
                cab: .init(length: 5.2, doors: [0.3 ... 0.37], bogies: [0.15, 0.85], windowsFrom: 0.1),
                trailer: .init(length: 5.2, doors: [0.06 ... 0.13], bogies: [0.15, 0.85]),
                jacobsBogies: false,
                windowWidth: 0.5,
                windowPitch: 0.58,
                windowTop: 0.21,
                windowBottom: 0.46,
                doorTop: 0.14,
                doorBottom: 0.76,
                doubleDoors: false,
                livery: .init(
                    body: Color(rgb: 0xA9ADB0), door: Color(rgb: 0x9A9EA1), front: Color(rgb: 0x1D1E20),
                    skirt: Color(rgb: 0x4A4D50), windowBand: Color(rgb: 0x55595D)
                ),
                pantograph: 0.4
            )
        case .x3:
            RollingStockProfile(
                nose: .wedge,
                cab: .init(length: 4.6, doors: [0.25 ... 0.3, 0.8 ... 0.85], bogies: [0.13, 0.87], windowsFrom: 0.25),
                trailer: .init(length: 4.6, doors: [0.15 ... 0.2, 0.8 ... 0.85], bogies: [0.13, 0.87]),
                jacobsBogies: false,
                windowWidth: 0.4,
                windowPitch: 0.44,
                windowTop: 0.2,
                windowBottom: 0.44,
                doubleDoors: false,
                livery: .init(
                    body: Color(rgb: 0xF1F1EF), door: Color(rgb: 0xDADBD8), front: Color(rgb: 0xF5D10A),
                    accent: Color(rgb: 0xF5D10A), skirt: Color(rgb: 0x8C8F92), windowBand: Color(rgb: 0x2A2C30)
                ),
                pantograph: 0.5
            )
        case .x74:
            RollingStockProfile(
                nose: .bubble,
                cab: .init(length: 4.1, doors: [0.24 ... 0.28, 0.5 ... 0.6], bogies: [0.14], windowsFrom: 0.18),
                trailer: .init(length: 4.1, doors: [0.08 ... 0.18], bogies: []),
                jacobsBogies: true,
                windowWidth: 0.24,
                windowPitch: 0.5,
                doubleDoors: true,
                livery: .init(
                    body: Color(rgb: 0x5DBE3F), trailerBody: Color(rgb: 0xE9EAE8), door: Color(rgb: 0x4FA836),
                    front: Color(rgb: 0x5DBE3F), accent: Color(rgb: 0xD9262E)
                ),
                pantograph: 0.45
            )
        }
    }
}

// MARK: - Drawing

/// The cab car and the start of the next cars, fading out to the right.
private struct RollingStockDrawing: View {
    private struct PlacedCar {
        var start: Double
        var car: RollingStockProfile.Car
        var isCab: Bool
    }

    let profile: RollingStockProfile

    private static let gap = 0.08
    private static let unitHeight = 1.16
    private static let roofClearance = 0.14
    private static let glass = Color(rgb: 0x23262B)
    private static let running = Color(rgb: 0x3A3C40)

    private var bottom: Double {
        RollingStockProfile.bodyBottom
    }

    var body: some View {
        Canvas { context, size in
            guard size.height > 0 else { return }
            let scale = size.height / Self.unitHeight
            context.translateBy(x: 0.14 * scale, y: Self.roofClearance * scale)
            context.scaleBy(x: scale, y: scale)
            draw(in: context, width: size.width / scale)
        }
        .mask {
            LinearGradient(
                stops: [.init(color: .black, location: 0.72), .init(color: .clear, location: 1)],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    private func draw(in context: GraphicsContext, width: Double) {
        // Rail.
        context.fill(Path(CGRect(x: -0.2, y: 1.0, width: width + 0.2, height: 0.025)), with: .color(.secondary.opacity(0.5)))

        var cars: [PlacedCar] = [PlacedCar(start: 0, car: profile.cab, isCab: true)]
        var x = profile.cab.length + Self.gap
        while x < width {
            cars.append(PlacedCar(start: x, car: profile.trailer, isCab: false))
            x += profile.trailer.length + Self.gap
        }

        drawRunningGear(in: context, cars: cars)
        drawFrontGear(in: context)
        for item in cars {
            drawCar(item.car, at: item.start, isCab: item.isCab, in: context)
        }
        drawPantograph(in: context, x: cars.count > 1 ? cars[1].start + profile.trailer.length * profile.pantograph : 2)
    }

    // MARK: Car bodies

    private func drawCar(_ car: RollingStockProfile.Car, at start: Double, isCab: Bool, in context: GraphicsContext) {
        let livery = profile.livery
        let outline = isCab ? cabOutline(length: car.length) : Path(
            roundedRect: CGRect(x: start, y: 0, width: car.length, height: bottom),
            cornerRadius: 0.07
        )
        context.fill(outline, with: .color(isCab ? livery.body : (livery.trailerBody ?? livery.body)))

        var body = context
        body.clip(to: outline)

        if let skirt = livery.skirt {
            body.fill(Path(CGRect(x: start, y: bottom - 0.1, width: car.length, height: 0.1)), with: .color(skirt))
        }
        if let accent = livery.accent, profile.nose == .visor {
            // SL's thin cantrail stripes.
            for y in [0.08, 0.12] {
                body.fill(Path(CGRect(x: start, y: y, width: car.length, height: 0.018)), with: .color(accent))
            }
        }
        if profile.nose == .wedge, let accent = livery.accent {
            body.fill(Path(CGRect(x: start, y: 0, width: car.length, height: 0.035)), with: .color(accent))
        }
        if !isCab, profile.nose == .bubble {
            // VR's green speed lines towards the car ends.
            for index in 0 ..< 5 {
                let y = 0.2 + Double(index) * 0.1
                body.fill(
                    Path(CGRect(x: start + car.length - 0.9 + Double(index) * 0.08, y: y, width: 0.9, height: 0.03)),
                    with: .color(livery.body)
                )
            }
        }
        if isCab {
            drawNoseLivery(in: body, length: car.length)
        }

        let doors = car.doors.map { (start + $0.lowerBound * car.length) ... (start + $0.upperBound * car.length) }
        drawWindows(in: body, from: start + car.windowsFrom * car.length, to: start + car.windowsTo * car.length, doors: doors)
        for door in doors {
            drawDoor(door, in: body)
        }

        context.stroke(outline, with: .color(.black.opacity(0.35)), lineWidth: 0.02)
    }

    /// Windows centred in every stretch between doors, so they never run through one.
    private func drawWindows(in context: GraphicsContext, from: Double, to: Double, doors: [ClosedRange<Double>]) {
        let margin = 0.08
        var edges = [from]
        for door in doors.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            edges.append(door.lowerBound - margin)
            edges.append(door.upperBound + margin)
        }
        edges.append(to)
        let height = profile.windowBottom - profile.windowTop
        for index in stride(from: 0, to: edges.count - 1, by: 2) {
            let lower = edges[index], upper = edges[index + 1]
            let span = upper - lower
            let count = Int((span - profile.windowWidth) / profile.windowPitch) + 1
            guard span >= profile.windowWidth, count > 0 else { continue }
            let used = profile.windowWidth + Double(count - 1) * profile.windowPitch
            let first = lower + (span - used) / 2
            if let band = profile.livery.windowBand {
                let rect = CGRect(x: first - 0.03, y: profile.windowTop - 0.03, width: used + 0.06, height: height + 0.06)
                context.fill(Path(roundedRect: rect, cornerRadius: 0.04), with: .color(band))
            }
            for window in 0 ..< count {
                let rect = CGRect(
                    x: first + Double(window) * profile.windowPitch,
                    y: profile.windowTop,
                    width: profile.windowWidth,
                    height: height
                )
                context.fill(Path(roundedRect: rect, cornerRadius: 0.035), with: .color(Self.glass))
            }
        }
    }

    private func drawDoor(_ door: ClosedRange<Double>, in context: GraphicsContext) {
        let rect = CGRect(
            x: door.lowerBound,
            y: profile.doorTop,
            width: door.upperBound - door.lowerBound,
            height: profile.doorBottom - profile.doorTop
        )
        let shape = Path(roundedRect: rect, cornerRadius: 0.03)
        context.fill(shape, with: .color(profile.livery.door))
        context.stroke(shape, with: .color(.black.opacity(0.45)), lineWidth: 0.015)
        // Narrow doors (cab doors) are single-leaf even on trains with double passenger doors.
        let leaves = profile.doubleDoors && rect.width > 0.3 ? 2 : 1
        let leafWidth = rect.width / Double(leaves)
        for leaf in 0 ..< leaves {
            let pane = CGRect(
                x: rect.minX + Double(leaf) * leafWidth + leafWidth * 0.28,
                y: profile.windowTop + 0.02,
                width: leafWidth * 0.44,
                height: 0.34
            )
            context.fill(Path(roundedRect: pane, cornerRadius: 0.02), with: .color(Self.glass))
        }
        if leaves == 2 {
            context.fill(
                Path(CGRect(x: rect.midX - 0.006, y: rect.minY, width: 0.012, height: rect.height)),
                with: .color(.black.opacity(0.45))
            )
        }
    }

    // MARK: Noses

    private func cabOutline(length: Double) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: length - 0.07, y: 0))
        switch profile.nose {
        case .visor:
            path.addLine(to: CGPoint(x: 0.95, y: 0))
            path.addCurve(to: CGPoint(x: 0.12, y: 0.42), control1: CGPoint(x: 0.45, y: 0), control2: CGPoint(x: 0.2, y: 0.18))
            path.addCurve(to: CGPoint(x: 0.1, y: bottom), control1: CGPoint(x: 0.02, y: 0.62), control2: CGPoint(x: 0.0, y: bottom))
        case .gangway:
            path.addLine(to: CGPoint(x: 0.22, y: 0))
            path.addQuadCurve(to: CGPoint(x: 0.07, y: 0.12), control: CGPoint(x: 0.08, y: 0))
            path.addLine(to: CGPoint(x: 0.02, y: 0.68))
            path.addQuadCurve(to: CGPoint(x: 0.14, y: bottom), control: CGPoint(x: 0.02, y: bottom))
        case .wedge:
            path.addLine(to: CGPoint(x: 1.25, y: 0))
            path.addCurve(to: CGPoint(x: 0.0, y: 0.6), control1: CGPoint(x: 0.6, y: 0.0), control2: CGPoint(x: 0.08, y: 0.32))
            path.addQuadCurve(to: CGPoint(x: 0.1, y: bottom), control: CGPoint(x: -0.04, y: bottom))
        case .bubble:
            path.addLine(to: CGPoint(x: 0.85, y: 0))
            path.addCurve(to: CGPoint(x: 0.06, y: 0.48), control1: CGPoint(x: 0.3, y: 0), control2: CGPoint(x: 0.08, y: 0.2))
            path.addLine(to: CGPoint(x: 0.06, y: 0.56))
            path.addLine(to: CGPoint(x: 0.0, y: 0.58))
            path.addLine(to: CGPoint(x: 0.0, y: 0.7))
            path.addQuadCurve(to: CGPoint(x: 0.12, y: bottom), control: CGPoint(x: 0.0, y: bottom))
        }
        path.addLine(to: CGPoint(x: length - 0.07, y: bottom))
        path.addQuadCurve(to: CGPoint(x: length, y: bottom - 0.07), control: CGPoint(x: length, y: bottom))
        path.addLine(to: CGPoint(x: length, y: 0.07))
        path.addQuadCurve(to: CGPoint(x: length - 0.07, y: 0), control: CGPoint(x: length, y: 0))
        path.closeSubpath()
        return path
    }

    /// Front colours and windscreen, drawn inside the cab's clip so they follow its outline.
    private func drawNoseLivery(in context: GraphicsContext, length: Double) {
        let livery = profile.livery
        func polygon(_ points: [(Double, Double)]) -> Path {
            Path { path in
                path.addLines(points.map { CGPoint(x: $0.0, y: $0.1) })
                path.closeSubpath()
            }
        }
        switch profile.nose {
        case .visor:
            // Lighter swoosh rising from the chin to behind the visor.
            context.fill(
                polygon([(-1, 0.8), (0.3, 0.8), (1.1, 0.12), (1.3, 0.12), (0.5, bottom + 0.1), (-1, bottom + 0.1)]),
                with: .color(livery.front)
            )
            context.fill(polygon([(-1, 0.05), (0.82, 0.05), (0.6, 0.2), (0.32, 0.42), (-1, 0.42)]), with: .color(Self.glass))
            context.fill(Path(ellipseIn: CGRect(x: 0.1, y: 0.5, width: 0.16, height: 0.06)), with: .color(.white.opacity(0.85)))
        case .gangway:
            context.fill(Path(CGRect(x: -1, y: -1, width: 1.34, height: 3)), with: .color(livery.front))
            context.fill(polygon([(-1, 0.14), (0.16, 0.14), (0.12, 0.42), (-1, 0.42)]), with: .color(Self.glass.opacity(0.9)))
            context.fill(
                Path(CGRect(x: 0.42, y: profile.windowTop, width: 0.18, height: profile.windowBottom - profile.windowTop)),
                with: .color(Self.glass)
            )
        case .wedge:
            context.fill(polygon([(-1, -1), (1.55, -1), (1.55, 0.03), (0.55, bottom), (-1, bottom)]), with: .color(livery.front))
            context.fill(polygon([(-1, 0.06), (1.05, 0.06), (0.85, 0.33), (-1, 0.33)]), with: .color(Self.glass))
            context.fill(Path(ellipseIn: CGRect(x: 0.06, y: 0.47, width: 0.16, height: 0.05)), with: .color(.white.opacity(0.9)))
        case .bubble:
            context.fill(polygon([(-1, 0.04), (0.72, 0.04), (0.52, 0.2), (0.34, 0.42), (-1, 0.42)]), with: .color(Self.glass))
            if let accent = livery.accent {
                context.fill(Path(CGRect(x: -1, y: 0.6, width: 1.2, height: 0.05)), with: .color(accent))
            }
            context.fill(Path(CGRect(x: 0.07, y: 0.5, width: 0.14, height: 0.04)), with: .color(.white.opacity(0.85)))
        }
    }

    /// Coupler, buffer beam and snow plough ahead of the nose.
    private func drawFrontGear(in context: GraphicsContext) {
        switch profile.nose {
        case .visor:
            context.fill(
                Path(roundedRect: CGRect(x: -0.1, y: 0.62, width: 0.16, height: 0.1), cornerRadius: 0.02),
                with: .color(Self.running)
            )
        case .gangway:
            context.fill(Path(CGRect(x: -0.05, y: 0.68, width: 0.1, height: 0.07)), with: .color(Self.running))
        case .wedge, .bubble:
            var plough = Path()
            plough.move(to: CGPoint(x: 0.06, y: bottom - 0.02))
            plough.addLine(to: CGPoint(x: 0.5, y: bottom - 0.02))
            plough.addLine(to: CGPoint(x: 0.42, y: 0.95))
            plough.addLine(to: CGPoint(x: 0.12, y: 0.95))
            plough.closeSubpath()
            context.fill(plough, with: .color(Self.running))
            if profile.nose == .bubble {
                context.fill(
                    Path(roundedRect: CGRect(x: -0.12, y: 0.63, width: 0.18, height: 0.1), cornerRadius: 0.02),
                    with: .color(Self.running)
                )
            }
        }
    }

    // MARK: Running gear and roof

    private func drawRunningGear(in context: GraphicsContext, cars: [PlacedCar]) {
        var centres: [Double] = []
        for (index, item) in cars.enumerated() {
            centres += item.car.bogies.map { item.start + $0 * item.car.length }
            if profile.jacobsBogies, index > 0 {
                centres.append(item.start - Self.gap / 2)
            }
        }
        for centre in centres {
            context.fill(
                Path(roundedRect: CGRect(x: centre - 0.36, y: bottom - 0.02, width: 0.72, height: 0.09), cornerRadius: 0.03),
                with: .color(Self.running)
            )
            for wheel in [centre - 0.2, centre + 0.2] {
                context.fill(
                    Path(ellipseIn: CGRect(x: wheel - 0.085, y: 1.0 - 0.17, width: 0.17, height: 0.17)),
                    with: .color(Self.running)
                )
            }
        }
    }

    private func drawPantograph(in context: GraphicsContext, x: Double) {
        context.fill(
            Path(roundedRect: CGRect(x: x - 0.2, y: -0.035, width: 0.4, height: 0.04), cornerRadius: 0.01),
            with: .color(Self.running)
        )
        var arm = Path()
        arm.move(to: CGPoint(x: x - 0.1, y: -0.035))
        arm.addLine(to: CGPoint(x: x + 0.22, y: -0.08))
        arm.addLine(to: CGPoint(x: x + 0.02, y: -0.125))
        arm.move(to: CGPoint(x: x - 0.14, y: -0.125))
        arm.addLine(to: CGPoint(x: x + 0.2, y: -0.125))
        context.stroke(arm, with: .color(Self.running), style: StrokeStyle(lineWidth: 0.02, lineCap: .round, lineJoin: .round))
    }
}

private extension Color {
    init(rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}

#Preview {
    List {
        ForEach(RollingStock.allCases, id: \.self) { stock in
            RollingStockView(stock: stock)
        }
    }
}
