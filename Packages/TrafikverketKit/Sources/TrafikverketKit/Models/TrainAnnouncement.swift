import Foundation

/// One arrival or departure event for one train at one station.
public struct TrainAnnouncement: TRVObject, Hashable, Identifiable {
    public static let objectType = "TrainAnnouncement"
    public static let namespace: String? = "rail.trafficinfo"
    public static let schemaVersion = "2.0"

    public enum ActivityType: String, Codable, Hashable, Sendable {
        case arrival = "Ankomst"
        case departure = "Avgang"
    }

    public var activityId: String
    public var activityType: ActivityType?
    public var advertised: Bool?
    public var advertisedTimeAtLocation: Date?
    public var advertisedTrainIdent: String?
    public var booking: [CodeDescription]?
    public var canceled: Bool?
    public var deleted: Bool?
    public var departureDateOTN: Date?
    public var deviation: [CodeDescription]?
    public var estimatedTimeAtLocation: Date?
    public var estimatedTimeIsPreliminary: Bool?
    public var fromLocation: [LocationReference]?
    public var informationOwner: String?
    public var locationDateTimeOTN: Date?
    public var locationSignature: String?
    public var mobileWebLink: String?
    public var modifiedTime: Date?
    public var newEquipment: Int?
    public var `operator`: String?
    public var operationalTrainNumber: String?
    public var otherInformation: [CodeDescription]?
    public var plannedEstimatedTimeAtLocation: Date?
    public var plannedEstimatedTimeAtLocationIsValid: Bool?
    public var productInformation: [CodeDescription]?
    public var scheduledDepartureDateTime: Date?
    public var service: [CodeDescription]?
    public var timeAtLocation: Date?
    public var timeAtLocationWithSeconds: Date?
    public var toLocation: [LocationReference]?
    public var trackAtLocation: String?
    public var trainComposition: [CodeDescription]?
    public var trainOwner: String?
    public var typeOfTraffic: [CodeDescription]?
    public var viaFromLocation: [LocationReference]?
    public var viaToLocation: [LocationReference]?
    public var webLink: String?
    public var webLinkName: String?

    enum CodingKeys: String, CodingKey {
        case activityId = "ActivityId"
        case activityType = "ActivityType"
        case advertised = "Advertised"
        case advertisedTimeAtLocation = "AdvertisedTimeAtLocation"
        case advertisedTrainIdent = "AdvertisedTrainIdent"
        case booking = "Booking"
        case canceled = "Canceled"
        case deleted = "Deleted"
        case departureDateOTN = "DepartureDateOTN"
        case deviation = "Deviation"
        case estimatedTimeAtLocation = "EstimatedTimeAtLocation"
        case estimatedTimeIsPreliminary = "EstimatedTimeIsPreliminary"
        case fromLocation = "FromLocation"
        case informationOwner = "InformationOwner"
        case locationDateTimeOTN = "LocationDateTimeOTN"
        case locationSignature = "LocationSignature"
        case mobileWebLink = "MobileWebLink"
        case modifiedTime = "ModifiedTime"
        case newEquipment = "NewEquipment"
        case `operator` = "Operator"
        case operationalTrainNumber = "OperationalTrainNumber"
        case otherInformation = "OtherInformation"
        case plannedEstimatedTimeAtLocation = "PlannedEstimatedTimeAtLocation"
        case plannedEstimatedTimeAtLocationIsValid = "PlannedEstimatedTimeAtLocationIsValid"
        case productInformation = "ProductInformation"
        case scheduledDepartureDateTime = "ScheduledDepartureDateTime"
        case service = "Service"
        case timeAtLocation = "TimeAtLocation"
        case timeAtLocationWithSeconds = "TimeAtLocationWithSeconds"
        case toLocation = "ToLocation"
        case trackAtLocation = "TrackAtLocation"
        case trainComposition = "TrainComposition"
        case trainOwner = "TrainOwner"
        case typeOfTraffic = "TypeOfTraffic"
        case viaFromLocation = "ViaFromLocation"
        case viaToLocation = "ViaToLocation"
        case webLink = "WebLink"
        case webLinkName = "WebLinkName"
    }

    public var id: String {
        activityId
    }

    /// The best-known time: actual if recorded, otherwise estimated, otherwise the timetable time.
    public var bestKnownTime: Date? {
        timeAtLocation ?? estimatedTimeAtLocation ?? advertisedTimeAtLocation
    }

    /// Delay relative to the timetable, in seconds. Positive is late. `nil` when no comparison is possible.
    public var delay: TimeInterval? {
        guard let advertised = advertisedTimeAtLocation,
              let known = timeAtLocation ?? estimatedTimeAtLocation else { return nil }
        return known.timeIntervalSince(advertised)
    }

    public var isCanceled: Bool {
        canceled ?? false
    }

    /// The track this train uses at the station, or `nil` when none is announced: the field comes
    /// back blank, and as "X" for a train that is not given a track at all (a pass-through).
    public var announcedTrack: String? {
        let value = trackAtLocation?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty || value.lowercased() == "x" ? nil : value
    }

    public var hasDeparted: Bool {
        timeAtLocation != nil
    }

    /// Whether this is a "planned" delay (published in advance, e.g. track work).
    public var hasValidPlannedDelay: Bool {
        (plannedEstimatedTimeAtLocationIsValid ?? false) && plannedEstimatedTimeAtLocation != nil
    }

    /// The set of fields the app requests. Kept explicit so payloads stay small.
    public static let appFields: [String] = [
        "ActivityId", "ActivityType", "Advertised", "AdvertisedTimeAtLocation", "AdvertisedTrainIdent",
        "Booking", "Canceled", "Deleted", "Deviation", "EstimatedTimeAtLocation", "EstimatedTimeIsPreliminary",
        "FromLocation", "InformationOwner", "LocationSignature", "ModifiedTime", "Operator",
        "OperationalTrainNumber", "OtherInformation", "PlannedEstimatedTimeAtLocation",
        "PlannedEstimatedTimeAtLocationIsValid", "ProductInformation", "ScheduledDepartureDateTime",
        "Service", "TimeAtLocation", "TimeAtLocationWithSeconds", "ToLocation", "TrackAtLocation", "TrainComposition", "TrainOwner",
        "TypeOfTraffic", "ViaFromLocation", "ViaToLocation", "WebLink", "WebLinkName", "MobileWebLink",
    ]
}
