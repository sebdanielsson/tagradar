import SwiftUI
import TrafikverketKit
import WidgetKit

struct DepartureItem: Hashable, Sendable, Identifiable {
    let id: String
    let ident: String
    let planned: Date?
    /// The day the run itself departed, which is not the day it calls here when that happens after
    /// midnight. `TrainKey` is built from this, the way `StationBoardView` already does it.
    let scheduledDeparture: Date?
    let expected: Date?
    let destination: String
    let product: String?
    let track: String?
    let canceled: Bool
    let delay: TimeInterval?

    init(_ row: TrainAnnouncement, names: StationNames) {
        id = row.activityId
        ident = row.advertisedTrainIdent ?? "–"
        planned = row.advertisedTimeAtLocation
        scheduledDeparture = row.scheduledDepartureDateTime
        expected = row.estimatedTimeAtLocation ?? row.timeAtLocation
        let targets = (row.toLocation ?? []).sorted { ($0.order ?? 0) < ($1.order ?? 0) }
        destination = targets.map { names.shortName($0.locationName) }.joined(separator: " / ")
        product = row.displayProduct
        track = row.announcedTrack
        canceled = row.isCanceled
        delay = row.delay
    }

    var deepLink: URL? {
        guard ident != "–", let day = scheduledDeparture ?? planned else { return nil }
        return URL(string: "tagradar://train/\(TrainKey(ident: ident, departureDate: day).id)")
    }
}

struct StationDeparturesEntry: TimelineEntry {
    enum Content {
        case board(station: String, signature: String, departures: [DepartureItem])
        case noStation
        case noAPIKey
        case failed
        case placeholder
    }

    let date: Date
    let content: Content
}

struct StationDeparturesProvider: AppIntentTimelineProvider {
    func placeholder(in _: Context) -> StationDeparturesEntry {
        StationDeparturesEntry(date: .now, content: .placeholder)
    }

    func snapshot(for configuration: StationDeparturesConfigurationIntent, in _: Context) async -> StationDeparturesEntry {
        await entry(for: configuration)
    }

    func timeline(for configuration: StationDeparturesConfigurationIntent, in _: Context) async -> Timeline<StationDeparturesEntry> {
        let entry = await entry(for: configuration)
        let interval: TimeInterval = if case .board = entry.content {
            10 * 60
        } else {
            30 * 60
        }
        return Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(interval)))
    }

    private func entry(for configuration: StationDeparturesConfigurationIntent) async -> StationDeparturesEntry {
        let client = await MainActor.run { WidgetEnvironment.makeClient() }
        let favorites = await MainActor.run { WidgetEnvironment.favoriteStations() }
        let names = await WidgetEnvironment.stationNames(client: client)
        let signature = configuration.station?.id ?? favorites.first?.signature
        guard let signature else { return StationDeparturesEntry(date: .now, content: .noStation) }
        guard let client else { return StationDeparturesEntry(date: .now, content: .noAPIKey) }
        let stationName = configuration.station?.name ?? names.name(signature)
        do {
            let rows = try await TrainService(client: client)
                .departures(from: signature, start: .now.addingTimeInterval(-2 * 60), hours: 6, limit: 30)
            let items = rows.map { DepartureItem($0, names: names) }
            return StationDeparturesEntry(date: .now, content: .board(station: stationName, signature: signature, departures: items))
        } catch {
            return StationDeparturesEntry(date: .now, content: .failed)
        }
    }
}

struct StationDeparturesWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "StationDepartures",
            intent: StationDeparturesConfigurationIntent.self,
            provider: StationDeparturesProvider()
        ) { entry in
            StationDeparturesView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Departures")
        .description("The next departures from a station of your choice.")
        .supportedFamilies([.systemMedium, .systemLarge, .accessoryRectangular])
    }
}

struct StationDeparturesView: View {
    let entry: StationDeparturesEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch entry.content {
        case let .board(station, signature, departures):
            board(station: station, signature: signature, departures: departures)
                .widgetURL(URL(string: "tagradar://station/\(signature)"))
        case .placeholder:
            board(station: "Stockholm Central", signature: nil, departures: [])
                .redacted(reason: .placeholder)
        case .noStation:
            message("No station chosen", detail: "Edit the widget to pick a station, or star one in Tågradar.", icon: "building.columns")
        case .noAPIKey:
            message("No API key", detail: "Add a Trafikverket key in Settings.", icon: "key")
        case .failed:
            message("Could not load", detail: "Trafikverket did not answer. Trying again shortly.", icon: "wifi.exclamationmark")
        }
    }

    private var rowLimit: Int {
        switch family {
        case .systemLarge: 8
        case .accessoryRectangular: 2
        default: 3
        }
    }

    @ViewBuilder
    private func board(station: String, signature: String?, departures: [DepartureItem]) -> some View {
        let rows = Array(departures.filter { !$0.canceled || family != .accessoryRectangular }.prefix(rowLimit))
        VStack(alignment: .leading, spacing: family == .accessoryRectangular ? 0 : 6) {
            HStack(spacing: 6) {
                if family != .accessoryRectangular {
                    Image(systemName: "building.columns.fill").foregroundStyle(.tint)
                }
                Text(station).font(family == .accessoryRectangular ? .headline : .headline).lineLimit(1)
                Spacer()
                if family != .accessoryRectangular {
                    Text("Departures").font(.caption).foregroundStyle(.secondary)
                }
            }
            if rows.isEmpty {
                Spacer(minLength: 0)
                Text("No departures in the next six hours.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ForEach(rows) { item in
                    if family == .accessoryRectangular {
                        accessoryRow(item)
                    } else {
                        row(item, signature: signature)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .widgetAccentable(family == .accessoryRectangular)
    }

    /// A departure with no advertised number has no train to open, so the row falls back to the
    /// board it came from. `tagradar://station` on its own carries no signature and is ignored by
    /// `AppNavigation`, which made those rows dead to the touch.
    private func row(_ item: DepartureItem, signature: String?) -> some View {
        let board = signature.flatMap { URL(string: "tagradar://station/\($0)") }
        return Link(destination: item.deepLink ?? board ?? URL(string: "tagradar://")!) {
            HStack(spacing: 8) {
                TimePair(planned: item.planned, expected: item.expected, canceled: item.canceled, font: .subheadline.weight(.semibold))
                    .frame(minWidth: 44, alignment: .leading)
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.destination).font(.subheadline).lineLimit(1)
                    Text([item.product, item.ident].compactMap(\.self).joined(separator: " "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                if item.canceled {
                    Text("Canceled").font(.caption2.weight(.semibold)).foregroundStyle(.red)
                } else {
                    TrackChip(track: item.track, compact: true)
                }
            }
        }
    }

    private func accessoryRow(_ item: DepartureItem) -> some View {
        HStack(spacing: 4) {
            Text(Format.clock(item.expected ?? item.planned)).font(.caption.weight(.semibold)).monospacedDigit()
            Text(item.destination).font(.caption).lineLimit(1)
            Spacer(minLength: 0)
            // Flat on purpose: this family renders accented and monochrome, where the chip's
            // background washes out. It still owes VoiceOver the same label the chip gives.
            if let track = item.track {
                Text(track)
                    .font(.caption2.weight(.semibold))
                    .accessibilityLabel(Text("Track \(track)"))
            }
        }
    }

    private func message(_ title: LocalizedStringKey, detail: LocalizedStringKey, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title2).foregroundStyle(.secondary)
            Text(title).font(.headline)
            if family != .accessoryRectangular {
                Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }
}
