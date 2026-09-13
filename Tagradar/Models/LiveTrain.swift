import CoreLocation
import Foundation
import TrafikverketKit

/// A train with a live GPS fix, as shown on the map.
struct LiveTrain: Identifiable, Hashable, Sendable {
    let position: TrainPosition
    let coordinate: Coordinate

    init?(_ position: TrainPosition) {
        guard let coordinate = position.coordinate else { return nil }
        self.position = position
        self.coordinate = coordinate
    }

    var id: String {
        position.id
    }

    /// The number a passenger recognises; falls back to the operational number for non-advertised trains.
    var displayNumber: String {
        position.train?.advertisedTrainNumber ?? position.train?.operationalTrainNumber ?? "?"
    }

    var isAdvertised: Bool {
        position.train?.advertisedTrainNumber != nil
    }

    var bearing: Int? {
        position.bearing
    }

    var speed: Int? {
        position.speed
    }

    var timestamp: Date? {
        position.timeStamp
    }

    var isActive: Bool {
        position.isActive
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    /// Key for looking up the timetable, when the train is advertised.
    var key: TrainKey? {
        guard let ident = position.train?.advertisedTrainNumber else { return nil }
        let day = position.train?.operationalTrainDepartureDate ?? position.timeStamp ?? .now
        return TrainKey(ident: ident, departureDate: day)
    }

    func isStale(at date: Date) -> Bool {
        guard let timestamp else { return true }
        return date.timeIntervalSince(timestamp) > 10 * 60
    }
}
