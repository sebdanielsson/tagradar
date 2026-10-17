import SwiftUI
import WidgetKit

struct SavedTrainEntry: TimelineEntry {
    enum Content {
        case train(TrainSnapshot)
        case noSavedTrains
        case noAPIKey
        case placeholder
    }

    let date: Date
    let content: Content
    var names: StationNames = .empty
}

struct SavedTrainProvider: AppIntentTimelineProvider {
    func placeholder(in _: Context) -> SavedTrainEntry {
        SavedTrainEntry(date: .now, content: .placeholder)
    }

    func snapshot(for configuration: SavedTrainConfigurationIntent, in _: Context) async -> SavedTrainEntry {
        await entry(for: configuration, refreshJourney: false)
    }

    func timeline(for configuration: SavedTrainConfigurationIntent, in _: Context) async -> Timeline<SavedTrainEntry> {
        let entry = await entry(for: configuration, refreshJourney: true)
        return Timeline(entries: [entry], policy: .after(Self.nextRefresh(for: entry)))
    }

    private func entry(for configuration: SavedTrainConfigurationIntent, refreshJourney: Bool) async -> SavedTrainEntry {
        let client = await MainActor.run { WidgetEnvironment.makeClient() }
        let saved = await MainActor.run { WidgetEnvironment.savedTrains() }
        let names = await WidgetEnvironment.stationNames(client: client)
        let upcoming = saved.filter { !$0.isOver }
        let chosen: TrainSnapshot? = if let id = configuration.train?.id {
            saved.first { $0.id == id }
        } else {
            upcoming.first
        }
        guard var snapshot = chosen else {
            return SavedTrainEntry(date: .now, content: .noSavedTrains, names: names)
        }
        guard let client else {
            return SavedTrainEntry(date: .now, content: .noAPIKey, names: names)
        }
        if refreshJourney {
            snapshot = await WidgetEnvironment.refresh(snapshot, client: client)
        }
        return SavedTrainEntry(date: .now, content: .train(snapshot), names: names)
    }

    /// Frequent while the train runs, relaxed when it is hours away. WidgetKit applies its own budget on top.
    static func nextRefresh(for entry: SavedTrainEntry, now: Date = .now) -> Date {
        guard case let .train(train) = entry.content else { return now.addingTimeInterval(30 * 60) }
        if train.status == .enRoute {
            return now.addingTimeInterval(5 * 60)
        }
        if let departure = train.bestDeparture {
            let untilDeparture = departure.timeIntervalSince(now)
            if untilDeparture < 2 * 3600 {
                return now.addingTimeInterval(10 * 60)
            }
            return now.addingTimeInterval(min(untilDeparture / 4, 3600))
        }
        return now.addingTimeInterval(30 * 60)
    }
}

struct SavedTrainWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "SavedTrain", intent: SavedTrainConfigurationIntent.self, provider: SavedTrainProvider()) { entry in
            SavedTrainWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Saved train")
        .description("Departure, delay and next stop for a saved train.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

struct SavedTrainWidgetView: View {
    let entry: SavedTrainEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch entry.content {
        case let .train(train):
            trainView(train)
                .widgetURL(train.deepLink)
        case .placeholder:
            trainView(.placeholder)
                .redacted(reason: .placeholder)
        case .noSavedTrains:
            message("No saved trains", detail: "Tap the star on a train in Tågradar.", icon: "star")
        case .noAPIKey:
            message("No API key", detail: "Add a Trafikverket key in Settings.", icon: "key")
        }
    }

    @ViewBuilder
    private func trainView(_ train: TrainSnapshot) -> some View {
        switch family {
        case .systemSmall: SmallTrainView(train: train, names: entry.names)
        case .systemMedium: MediumTrainView(train: train, names: entry.names)
        case .accessoryRectangular: RectangularTrainView(train: train, names: entry.names)
        case .accessoryInline: InlineTrainView(train: train)
        case .accessoryCircular: CircularTrainView(train: train)
        default: SmallTrainView(train: train, names: entry.names)
        }
    }

    @ViewBuilder
    private func message(_ title: LocalizedStringKey, detail: LocalizedStringKey, icon: String) -> some View {
        switch family {
        case .accessoryInline:
            Label(title, systemImage: icon)
        case .accessoryCircular:
            Image(systemName: icon).font(.title2)
        default:
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title2).foregroundStyle(.secondary)
                Text(title).font(.headline)
                if family != .accessoryRectangular {
                    Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
        }
    }
}

// MARK: Families

private struct TrainTitle: View {
    let train: TrainSnapshot

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "train.side.front.car")
                .foregroundStyle(.tint)
            Text("\(train.productName ?? String(localized: "Train")) \(train.ident)")
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

private struct StatusLine: View {
    let train: TrainSnapshot
    let names: StationNames

    /// The next stop's time on its own: the expected one in its delay colour, or the planned one
    /// when there is no estimate.
    private var nextStopTime: some View {
        let planned = train.nextStopPlanned
        let time = train.nextStopExpected ?? planned
        let delay = train.nextStopExpected.map { expected in expected.timeIntervalSince(planned ?? expected) }
        let severity = DelaySeverity.of(delay: delay, canceled: false)
        return Text(Format.clock(time))
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(severity == .onTime || severity == .unknown ? Color.primary : severity.color)
            .fixedSize()
    }

    var body: some View {
        switch train.status {
        case .canceled:
            Label("Canceled", systemImage: "xmark.circle.fill").foregroundStyle(.red)
        case .arrived:
            Label("Arrived \(Format.clock(train.bestArrival))", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .enRoute:
            if let next = train.nextStopSignature {
                // Both times when they fit; otherwise only the one the train will actually keep, so
                // the stop name is not squeezed to a letter or two on a narrow widget.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        Text("Next \(names.shortName(next))")
                        TimePair(planned: train.nextStopPlanned, expected: train.nextStopExpected, font: .caption)
                    }
                    HStack(spacing: 4) {
                        Text("Next \(names.shortName(next))").lineLimit(1)
                        nextStopTime
                    }
                }
            } else if let arrival = train.bestArrival {
                // The current delay is on the departure row (see `SmallTrainView`), so this line has
                // room for where the train is heading instead.
                Label("Arrives \(Format.clock(arrival))", systemImage: "flag.checkered")
            } else {
                DelayBadge(delay: train.delay, compact: true)
            }
        default:
            HStack(spacing: 4) {
                Text(Format.day(train.departureDate))
                if let track = train.originTrack {
                    Text("· Track \(track)")
                }
            }
        }
    }
}

struct SmallTrainView: View {
    let train: TrainSnapshot
    let names: StationNames

    @ViewBuilder
    private var delayBadge: some View {
        if train.status == .enRoute || train.status == .scheduled, let delay = train.delay, abs(delay) >= 60 {
            DelayBadge(delay: delay, compact: true)
        }
    }

    private var departureTimes: some View {
        TimePair(
            planned: train.scheduledDeparture,
            expected: train.expectedDeparture,
            canceled: train.isCanceled,
            font: .title2.weight(.semibold)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TrainTitle(train: train)
            Text("\(names.shortName(train.originSignature)) → \(names.shortName(train.destinationSignature))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            // The delay sits beside the departure time rather than at the end of the next-stop line:
            // that line already holds a stop name and its planned and expected times, and with the
            // badge too it truncated to "Next… … 1…" on narrow small widgets (an iPhone Duo's outer
            // display, smaller iPhones). A delayed departure shows two times, which rarely fit beside
            // the badge in a small widget, so the struck-through planned time goes first: the badge
            // carries the current delay, which for a train under way can differ from how late it left.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    departureTimes
                    Spacer(minLength: 0)
                    delayBadge
                }
                HStack(alignment: .firstTextBaseline) {
                    TimePair(
                        planned: train.expectedDeparture ?? train.scheduledDeparture,
                        expected: nil,
                        canceled: train.isCanceled,
                        font: .title2.weight(.semibold)
                    )
                    Spacer(minLength: 0)
                    delayBadge
                }
                departureTimes
            }
            StatusLine(train: train, names: names)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

struct MediumTrainView: View {
    let train: TrainSnapshot
    let names: StationNames

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                TrainTitle(train: train)
                Text(Format.day(train.departureDate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                endpoint(
                    names.name(train.originSignature),
                    planned: train.scheduledDeparture,
                    expected: train.expectedDeparture,
                    track: train.originTrack
                )
                endpoint(
                    names.name(train.destinationSignature),
                    planned: train.scheduledArrival,
                    expected: train.expectedArrival,
                    track: nil
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 6) {
                switch train.status {
                case .canceled: DelayBadge(delay: nil, canceled: true)
                case .arrived: Label("Arrived", systemImage: "checkmark.circle.fill").font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                default: DelayBadge(delay: train.delay ?? (train.status == .enRoute ? 0 : nil))
                }
                Spacer(minLength: 0)
                if train.status == .enRoute, let next = train.nextStopSignature {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("Next").font(.caption2).foregroundStyle(.secondary)
                        Text(names.shortName(next)).font(.subheadline.weight(.medium)).lineLimit(1)
                        TimePair(planned: train.nextStopPlanned, expected: train.nextStopExpected, font: .caption)
                        TrackChip(track: train.nextStopTrack, compact: true)
                    }
                } else if train.status == .scheduled, let departure = train.bestDeparture, departure > .now {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("Departs in").font(.caption2).foregroundStyle(.secondary)
                        Text(departure, style: .relative).font(.subheadline.weight(.medium)).monospacedDigit().lineLimit(1)
                    }
                }
            }
            .frame(minWidth: 90, alignment: .trailing)
        }
    }

    private func endpoint(_ name: String, planned: Date?, expected: Date?, track: String?) -> some View {
        HStack(spacing: 6) {
            TimePair(planned: planned, expected: expected, canceled: train.isCanceled, font: .subheadline.weight(.semibold))
            Text(name).font(.subheadline).lineLimit(1)
            TrackChip(track: track, compact: true)
        }
    }
}

struct RectangularTrainView: View {
    let train: TrainSnapshot
    let names: StationNames

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text("\(train.productName ?? String(localized: "Train")) \(train.ident)").font(.headline).lineLimit(1)
                Spacer(minLength: 2)
                if train.isCanceled {
                    Text("Canceled").font(.caption2.weight(.semibold))
                } else if let text = Format.delay(train.delay) {
                    Text(text).font(.caption2.weight(.semibold))
                }
            }
            Text("\(names.shortName(train.originSignature)) → \(names.shortName(train.destinationSignature))")
                .font(.caption)
                .lineLimit(1)
            HStack(spacing: 4) {
                TimePair(planned: train.scheduledDeparture, expected: train.expectedDeparture, canceled: train.isCanceled, font: .caption)
                if train.status == .enRoute, let next = train.nextStopSignature {
                    Text("· Next \(names.shortName(next))")
                } else if let track = train.originTrack {
                    Text("· Track \(track)")
                }
            }
            .font(.caption)
            .lineLimit(1)
        }
        .widgetAccentable()
    }
}

struct InlineTrainView: View {
    let train: TrainSnapshot

    var body: some View {
        if train.isCanceled {
            Label("\(train.ident) · \(String(localized: "Canceled"))", systemImage: "train.side.front.car")
        } else {
            let delay = Format.delay(train.delay).map { " · \($0)" } ?? ""
            Label("\(train.ident) · \(Format.clock(train.bestDeparture))\(delay)", systemImage: "train.side.front.car")
        }
    }
}

struct CircularTrainView: View {
    let train: TrainSnapshot

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: "train.side.front.car").font(.caption)
                Text(train.ident).font(.caption.weight(.bold)).minimumScaleFactor(0.6).lineLimit(1)
                if train.isCanceled {
                    Image(systemName: "xmark").font(.caption2.weight(.bold))
                } else if let delay = train.delay {
                    Text(delay >= 60 ? "+\(Int((delay / 60).rounded()))" : "✓").font(.caption2.weight(.semibold))
                } else {
                    Text(Format.clock(train.bestDeparture)).font(.system(size: 9).weight(.medium)).monospacedDigit()
                }
            }
        }
        .widgetAccentable()
    }
}

extension TrainSnapshot {
    /// Redacted sample for the widget gallery.
    static var placeholder: TrainSnapshot {
        var s = TrainSnapshot(favorite: FavoriteTrain(key: .today("537"), journey: nil))
        s.productName = "SJ Snabbtåg"
        s.originSignature = "Cst"
        s.destinationSignature = "G"
        s.scheduledDeparture = Date.now.addingTimeInterval(3600)
        s.scheduledArrival = Date.now.addingTimeInterval(4 * 3600)
        s.status = .scheduled
        return s
    }
}
