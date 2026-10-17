import SwiftData
import SwiftUI
import TrafikverketKit

/// The station shortcuts on the idle map sheet: starred stations first, then recently opened
/// ones, then the big hubs. A swipeable strip of circles in the iPhone card, a full list in the
/// iPad sidebar, which has the height for names and an icon saying why each station is here.
struct QuickStationsRow: View {
    var style: MapSheet.Style = .card
    var onSelectStation: (TrainStation) -> Void

    @Environment(StationDirectory.self) private var stations
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \FavoriteStation.createdAt) private var favoriteStations: [FavoriteStation]

    private enum Kind {
        case favorite, recent, major

        var symbol: String {
            switch self {
            case .favorite: "star.fill"
            case .recent: "clock.arrow.circlepath"
            case .major: "building.columns.fill"
            }
        }

        var tint: Color {
            switch self {
            case .favorite: .yellow
            case .recent: .accentColor
            // Darkened because `.gradient` lifts the top of the circle: plain `.gray` leaves the
            // white glyph at 2.6:1, under the 3:1 floor for graphical objects. Not `.secondary` —
            // that is a 60%-alpha *label* colour, so the bubble would tint with whatever is behind it.
            case .major: .gray.mix(with: .black, by: 0.25)
            }
        }

        /// The colour of the glyph itself in the sidebar list, which is the opposite job: the
        /// symbol is drawn *on* the card rather than under a white one, so the colour has to move
        /// with the appearance instead of staying put. The bubble's fixed dark gray measures
        /// 5.8:1 on a light card but 2.9:1 on a dark one — below the same floor it was chosen to
        /// clear. Mixing away from the background in both directions gives 5.8:1 and 7.8:1.
        func glyphTint(_ scheme: ColorScheme) -> Color {
            switch self {
            case .favorite: .yellow
            case .recent: .accentColor
            case .major: .gray.mix(with: scheme == .dark ? .white : .black, by: 0.25)
            }
        }
    }

    private struct Item: Identifiable {
        let station: TrainStation
        let kind: Kind
        var id: String {
            station.id
        }
    }

    private var items: [Item] {
        let majors = ["Cst", "G", "M", "U", "Lp", "Nr", "Vå", "Öb", "Hb", "Lu", "Gä", "Suc", "Umå"]
        var seen = Set<String>()
        let ordered: [(String, Kind)] = favoriteStations.map { ($0.signature, .favorite) }
            + settings.recentStations.map { ($0, .recent) }
            + majors.map { ($0, .major) }
        return ordered
            .filter { seen.insert($0.0).inserted }
            .compactMap { sig, kind in stations.station(sig).map { Item(station: $0, kind: kind) } }
            // The strip is swiped sideways, so it stops at a sensible number; the sidebar is a
            // scrolling list and showing every starred station is the point of it.
            .prefix(style == .sidebar ? .max : 14)
            .map(\.self)
    }

    var body: some View {
        let items = items
        // `StationDirectory` fills in asynchronously and resolves nothing until it does, so
        // offline on a first launch this would be a heading over an empty card.
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Stations")
                    .font(.title3.weight(.semibold))
                if style == .sidebar {
                    list(items)
                } else {
                    strip(items)
                }
            }
        }
    }

    /// The sidebar has the height for a proper list: full names, and the icon says why a station
    /// is here (starred, recent, or simply a big one).
    private func list(_ items: [Item]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button {
                    onSelectStation(item.station)
                } label: {
                    HStack {
                        Image(systemName: item.kind.symbol)
                            .foregroundStyle(item.kind.glyphTint(colorScheme))
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.station.name)
                            Text(item.station.locationSignature).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary).imageScale(.small)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                if index < items.count - 1 {
                    Divider().padding(.leading, 56)
                }
            }
        }
        .background(.fill.quaternary, in: .rect(cornerRadius: 16))
    }

    /// The card's compact take: a row of circles to swipe through.
    private func strip(_ items: [Item]) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(items) { item in
                    let station = item.station
                    Button {
                        onSelectStation(station)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: item.kind.symbol)
                                .font(.title3)
                                .foregroundStyle(.white)
                                .frame(width: 56, height: 56)
                                .background(item.kind.tint.gradient, in: .circle)
                            Text(station.advertisedShortLocationName ?? station.name)
                                .font(.caption)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .frame(width: 72)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
    }
}
