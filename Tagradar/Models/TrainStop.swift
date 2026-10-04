import Foundation
import TrafikverketKit

/// One station along a journey, combining the arrival and departure announcements.
struct TrainStop: Identifiable, Hashable, Sendable {
    let signature: String
    var arrival: TrainAnnouncement?
    var departure: TrainAnnouncement?

    var id: String {
        "\(signature)|\(arrival?.activityId ?? "")|\(departure?.activityId ?? "")"
    }

    /// The track to quote for someone getting on here, so the departure's when the two differ.
    var track: String? {
        departure?.announcedTrack ?? arrival?.announcedTrack
    }

    /// The track the train pulls in at — what a stop still ahead of you is asked about.
    var arrivalTrack: String? {
        arrival?.announcedTrack ?? departure?.announcedTrack
    }

    var isOrigin: Bool {
        arrival == nil && departure != nil
    }

    var isTerminus: Bool {
        departure == nil && arrival != nil
    }

    var isCanceled: Bool {
        switch (arrival, departure) {
        case let (a?, d?): a.isCanceled && d.isCanceled
        case let (a?, nil): a.isCanceled
        case let (nil, d?): d.isCanceled
        default: false
        }
    }

    var isPartlyCanceled: Bool {
        !isCanceled && ((arrival?.isCanceled ?? false) || (departure?.isCanceled ?? false))
    }

    /// Time the train has left (or, for the terminus, arrived at) this stop.
    var hasPassed: Bool {
        if let departure {
            return departure.hasDeparted
        }
        return arrival?.hasDeparted ?? false
    }

    var hasArrived: Bool {
        arrival?.hasDeparted ?? hasPassed
    }

    /// Sort key: the arrival timetable time, falling back to departure.
    var sortTime: Date? {
        arrival?.advertisedTimeAtLocation ?? departure?.advertisedTimeAtLocation
    }

    /// The most relevant delay for display: departure if known, otherwise arrival.
    var delay: TimeInterval? {
        departure?.delay ?? arrival?.delay
    }

    var deviations: [CodeDescription] {
        unique((arrival?.deviation ?? []) + (departure?.deviation ?? []))
    }

    var otherInformation: [CodeDescription] {
        unique((arrival?.otherInformation ?? []) + (departure?.otherInformation ?? []))
    }

    /// Car order and similar notes for this platform; they change along a run, e.g. when it reverses.
    var composition: [String] {
        // Some stops carry it on the arrival row only (seen for SJ 30 at Mdn).
        let departureNotes = departure?.trainComposition ?? []
        let notes = departureNotes.isEmpty ? arrival?.trainComposition ?? [] : departureNotes
        return unique(notes).compactMap(\.description)
    }

    private func unique(_ items: [CodeDescription]) -> [CodeDescription] {
        var seen = Set<String>()
        return items.filter { item in
            let key = item.description ?? item.code ?? ""
            return seen.insert(key).inserted
        }
    }
}
