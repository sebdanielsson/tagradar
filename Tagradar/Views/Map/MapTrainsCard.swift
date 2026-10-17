import SwiftData
import SwiftUI

/// The trains card at the top of the map sheet: the runs the user kept, and — in a second tab —
/// the ones they last opened. Both tabs render the same kind of row on purpose, so switching
/// between them is a change of source, not of reading.
struct MapTrainsCard: View {
    /// Whether this is the iPhone card or the iPad sidebar. The card keeps its four rows; the
    /// sidebar has the height to show every run, and to keep the ones that have already arrived
    /// within reach instead of dropping them.
    var style: MapSheet.Style = .card
    var onSelectTrain: (TrainKey) -> Void

    /// What the card is showing: what the user kept, or what they last looked at.
    enum Tab: String, CaseIterable, Identifiable {
        case saved, recent
        var id: String {
            rawValue
        }

        var title: LocalizedStringKey {
            self == .saved ? "Saved" : "Recent"
        }
    }

    @Environment(JourneyStore.self) private var journeyStore
    @Environment(AppSettings.self) private var settings
    @Environment(TrainMonitor.self) private var monitor
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FavoriteTrain.departureDate) private var favorites: [FavoriteTrain]
    /// The card always opens on Saved. Resolving a default from the lists instead looked tidier
    /// but latched: the picker writes its selection back, so one render before `@Query` had
    /// delivered the favorites was enough to leave the card stuck on Recent.
    @State private var tab: Tab = .saved
    @State private var showEarlier = false
    /// Bumped by this card's own save and unsave. The feedback keys off it rather than off the
    /// number of saved runs, because on iPad the inspector sits beside the card and its star
    /// moves that number as well — which fired this card's haptic on top of the detail's.
    @State private var toggles = 0

    private static let maxRows = 4
    /// How many timetables to ask for at once. The sidebar renders every saved run, so the number
    /// of rows is the user's to decide, and a long list should not open with a request per row.
    private static let maxConcurrentLoads = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if recents.isEmpty {
                Text("Saved trains")
                    .font(.title3.weight(.semibold))
            } else {
                Picker("Trains", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            switch visibleTab {
            case .saved: savedCard
            case .recent: recentCard
            }
        }
        // Once for the card rather than once per star: every visible star watching the same value
        // would fire a burst of haptics proportional to the number of rows.
        .sensoryFeedback(.success, trigger: toggles)
        // Here rather than on `earlierSection`: that view is removed in the same update that
        // empties the list, so an observer on it never sees the change and the group would come
        // back expanded the next time a saved run ages into it.
        .onChange(of: pastFavorites.isEmpty) { _, empty in
            if empty {
                showEarlier = false
            }
        }
    }

    /// Sorted by the time each row shows, not by the `@Query`'s `departureDate` — `TrainKey`
    /// normalises that to midnight, so runs saved for the same day tie and fall back to storage
    /// order, which here would also decide which four make the cut.
    private var upcomingFavorites: [FavoriteTrain] {
        favorites.filter { end(of: $0) > .now }
            .map { ($0, departure(of: $0)) }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// Runs that have already arrived, kept out of the main list but still reachable: without
    /// them a train saved for a trip that is over cannot be found or unsaved at all, short of
    /// searching the run up again. The card shows the same group as the sidebar, collapsed.
    private var pastFavorites: [FavoriteTrain] {
        favorites.filter { end(of: $0) <= .now }
            .map { ($0, departure(of: $0)) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// When a saved run stops being upcoming, plus three hours of slack. Read through the same
    /// snapshot as the row, so a trip segment ends at the alighting stop rather than at the
    /// terminus — otherwise someone who gets off halfway keeps the row in Saved for the rest of
    /// the run. `setSegment` clears the cached times when it has no journey to hand, so a segment
    /// can have an alighting stop and no time for it; the run's own arrival is the answer then.
    private func end(of fav: FavoriteTrain) -> Date {
        var snapshot = TrainSnapshot(favorite: fav)
        if let journey = journeyStore.cached(fav.key) {
            snapshot.apply(journey)
        }
        return TrainSnapshot.endOfRun(
            departureDate: fav.departureDate,
            scheduledArrival: snapshot.scheduledArrival ?? fav.scheduledArrival
        )
    }

    /// Whether to offer the "star a train" prompt. Only when this style has nothing to show at
    /// all: the sidebar keeps past runs below, so telling someone to save their first train while
    /// their saved trains sit just under it would be wrong.
    private var showsSavedPrompt: Bool {
        upcomingFavorites.isEmpty && pastFavorites.isEmpty
    }

    /// Read from the same snapshot `FavoriteTrainRow` renders, so a trip segment sorts by its
    /// boarding stop and a freshly pinned run takes its place as soon as its journey is cached.
    private func departure(of fav: FavoriteTrain) -> Date {
        var snapshot = TrainSnapshot(favorite: fav)
        if let journey = journeyStore.cached(fav.key) {
            snapshot.apply(journey)
        }
        return snapshot.scheduledDeparture ?? fav.departureDate
    }

    /// Everything the user opened, saved or not. A saved run still belongs here — it is part of
    /// what you were just looking at — and its star says which it is without a trip to the tab.
    private var recents: [RecentTrain] {
        settings.recentTrains
    }

    private func favorite(for recent: RecentTrain) -> FavoriteTrain? {
        favorites.first { $0.id == recent.id }
    }

    /// Falls back to Saved when the other tab has nothing left to show — a run can drop out of
    /// Recent while the user is looking at it, and an empty grey card is not an answer.
    private var visibleTab: Tab {
        recents.isEmpty ? .saved : tab
    }

    private var recentCard: some View {
        rows(recents) { recent in
            // A saved run renders from its favorite, trip segment and all. Reading it back from
            // the stored record instead would show whole-run times and a whole-run delay here
            // while the saved tab shows the user's leg — for the same train, one tap apart.
            if let favorite = favorite(for: recent) {
                FavoriteTrainRow(favorite: favorite, journey: journeyStore.cached(recent.key))
            } else {
                RecentTrainRow(recent: recent, journey: journeyStore.cached(recent.key))
            }
        } select: {
            onSelectTrain($0.key)
        } accessory: { recent in
            saveButton(for: recent)
        }
        .task(id: shown(recents).map(\.id)) {
            // A run starred from the detail view before its journey arrived has a favorite with
            // nothing in it, and the branch above renders that instead of this record — so the row
            // would drop to "Train 537 · – → –" while the record beside it still knows the route
            // and the times. Repaired here rather than while rendering, which must not write.
            // A successful load fills the favorite in too; this is what the offline case has.
            var repaired = false
            for recent in shown(recents) {
                if let favorite = favorite(for: recent), recent.fillIn(favorite) {
                    repaired = true
                }
            }
            if repaired {
                try? modelContext.save()
            }
            await load(shown(recents).map(\.key))
        }
    }

    @ViewBuilder
    private var savedCard: some View {
        if showsSavedPrompt {
            HStack(spacing: 12) {
                Image(systemName: "star")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 32)
                Text("Tap the star on a train to keep it here. Handy for a trip later this week.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quaternary, in: .rect(cornerRadius: 16))
        } else {
            if !upcomingFavorites.isEmpty {
                savedRows(upcomingFavorites)
                    .task(id: shown(upcomingFavorites).map(\.id)) {
                        await load(shown(upcomingFavorites).map(\.key))
                    }
            }
            if !pastFavorites.isEmpty {
                earlierSection
            }
        }
    }

    /// Saved runs that have already arrived, so they can still be reached and unsaved. Collapsed
    /// by default: they are history, not something to act on.
    private var earlierSection: some View {
        DisclosureGroup(isExpanded: $showEarlier) {
            savedRows(pastFavorites)
                .padding(.top, 10)
                // Only once the group is open: a run that has arrived still has a journey to
                // show, and the screen this replaced refreshed past favourites that had none,
                // but fetching them behind a collapsed disclosure would be work nobody asked for.
                .task(id: shown(pastFavorites).map(\.id)) {
                    await load(shown(pastFavorites).map(\.key))
                }
        } label: {
            Text("Earlier")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .tint(.secondary)
        .padding(.top, upcomingFavorites.isEmpty ? 0 : 4)
    }

    /// Saved rows carry the same star as the Recent tab, so a run can be unsaved from the list it
    /// is in — the only other way is to open the train and unstar it there.
    private func savedRows(_ items: [FavoriteTrain]) -> some View {
        rows(items) { fav in
            FavoriteTrainRow(favorite: fav, journey: journeyStore.cached(fav.key))
        } select: {
            onSelectTrain($0.key)
        } accessory: { fav in
            // Labelled for what it does: on these rows the star is always filled, so describing
            // the state would leave VoiceOver saying "Saved" on the control that removes.
            star(saved: true, label: "Remove") { unsave(fav) }
        }
    }

    /// Unsaves a run. Mirrors the star in `TrainDetailView` and in the Recent tab: the reminder
    /// has to be cancelled and the widgets refreshed, or a removed train still notifies.
    private func unsave(_ fav: FavoriteTrain) {
        let id = fav.id
        modelContext.delete(fav)
        try? modelContext.save()
        monitor.trainRemoved(id)
        toggles += 1
    }

    /// What this style actually renders, so the loader and the rows agree on the set.
    private func shown<Item>(_ items: [Item]) -> [Item] {
        style == .sidebar ? items : Array(items.prefix(Self.maxRows))
    }

    /// Concurrently but a few at a time: the sidebar lists every run, so awaiting each in turn
    /// would leave the last row blank for as many round trips, while starting them all at once
    /// would put a request per saved run on the wire. `JourneyStore` de-duplicates anything
    /// already in flight.
    private func load(_ keys: [TrainKey]) async {
        await withTaskGroup(of: Void.self) { group in
            var remaining = keys.makeIterator()
            for _ in 0 ..< Self.maxConcurrentLoads {
                guard let key = remaining.next() else { break }
                group.addTask { _ = try? await journeyStore.load(key) }
            }
            while await group.next() != nil {
                guard let key = remaining.next() else { continue }
                group.addTask { _ = try? await journeyStore.load(key) }
            }
        }
    }

    /// Says whether the run is saved, and saves or unsaves it without leaving the card.
    private func saveButton(for recent: RecentTrain) -> some View {
        let saved = favorite(for: recent) != nil
        return star(saved: saved, label: saved ? "Saved" : "Save") { toggleSaved(recent) }
    }

    private func star(saved: Bool, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: saved ? "star.fill" : "star")
                .font(.subheadline)
                .foregroundStyle(saved ? Color.yellow : Color.secondary)
                .frame(width: 40, height: 40)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    /// Mirrors the star in `TrainDetailView`: the same reminders and widget refresh have to follow,
    /// or a train saved from here would be one the monitor never looks at.
    private func toggleSaved(_ recent: RecentTrain) {
        if let existing = favorite(for: recent) {
            let id = existing.id
            modelContext.delete(existing)
            try? modelContext.save()
            monitor.trainRemoved(id)
        } else {
            let journey = journeyStore.cached(recent.key)
            let fav = FavoriteTrain(key: recent.key, journey: journey)
            recent.fillIn(fav)
            modelContext.insert(fav)
            try? modelContext.save()
            monitor.trainSaved(fav, journey: journey)
        }
        toggles += 1
    }

    /// The shared body of both tabs: tappable rows, divided, on one rounded card — four of them
    /// on the iPhone card, all of them in the sidebar.
    /// The accessory sits beside the row's button rather than inside its label — a button nested
    /// in another button's label never sees the tap.
    private func rows<Item: Identifiable>(
        _ items: [Item],
        @ViewBuilder row: @escaping (Item) -> some View,
        select: @escaping (Item) -> Void,
        @ViewBuilder accessory: @escaping (Item) -> some View
    ) -> some View {
        let shown = shown(items)
        return VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 0) {
                    Button {
                        select(item)
                    } label: {
                        row(item)
                            .padding(.leading, 14)
                            .padding(.vertical, 10)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    accessory(item)
                }
                .padding(.trailing, 14)
                if index < shown.count - 1 {
                    Divider().padding(.leading, 14)
                }
            }
        }
        .background(.fill.quaternary, in: .rect(cornerRadius: 16))
    }
}
