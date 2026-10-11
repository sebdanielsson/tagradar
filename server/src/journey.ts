import type { Announcement } from "./trafikverket.js";

// Port of `TrainJourney`, `TrainStop` and the `TrainAnnouncement` helpers they use. Keep the two in
// step: the contract fixtures in test/fixtures/contract run through both (see contract.test.ts and
// TagradarTests/PushContractTests.swift).

/** Operators that publish every row unadvertised although their trains carry passengers. */
const unadvertisedPassengerOperators = ["ATRAIN"];

/** `OperatorName.display`, for the operators above. */
const operatorNames: Record<string, string> = { ATRAIN: "Arlanda Express" };

export interface Stop {
  signature: string;
  arrival?: Announcement;
  departure?: Announcement;
}

export interface Journey {
  stops: Stop[];
  rows: Announcement[];
}

const isUnadvertisedPassengerOperator = (row: Announcement) =>
  row.operator !== undefined && unadvertisedPassengerOperators.includes(row.operator);

export const isPassengerActivity = (row: Announcement) => (row.advertised ?? true) || isUnadvertisedPassengerOperator(row);

export const hasDeparted = (row: Announcement) => row.actualTime !== undefined;

/** Actual if recorded, otherwise estimated, otherwise the timetable time. */
export const bestKnownTime = (row: Announcement | undefined) => row && (row.actualTime ?? row.estimatedTime ?? row.advertisedTime);

/** Seconds late against the timetable; undefined when there is nothing to compare. */
export function rowDelay(row: Announcement | undefined): number | undefined {
  const known = row && (row.actualTime ?? row.estimatedTime);
  if (row?.advertisedTime === undefined || known === undefined) {
    return undefined;
  }
  return (known - row.advertisedTime) / 1000;
}

/** Blank, and "X" for a train given no track, mean no track. */
export function announcedTrack(row: Announcement | undefined): string | undefined {
  const value = row?.trackAtLocation?.trim() ?? "";
  return value === "" || value.toLowerCase() === "x" ? undefined : value;
}

export function displayProduct(row: Announcement): string | undefined {
  if (row.products.length > 0) {
    return row.products[0];
  }
  return isUnadvertisedPassengerOperator(row) && row.operator ? (operatorNames[row.operator] ?? row.operator) : undefined;
}

export const stopTrack = (s: Stop) => announcedTrack(s.departure) ?? announcedTrack(s.arrival);
export const arrivalTrack = (s: Stop) => announcedTrack(s.arrival) ?? announcedTrack(s.departure);

export function stopIsCanceled(s: Stop): boolean {
  if (s.arrival && s.departure) {
    return s.arrival.canceled && s.departure.canceled;
  }
  return (s.arrival ?? s.departure)?.canceled ?? false;
}

export function hasPassed(s: Stop): boolean {
  if (s.departure) {
    return hasDeparted(s.departure);
  }
  return s.arrival ? hasDeparted(s.arrival) : false;
}

export const hasArrived = (s: Stop) => (s.arrival ? hasDeparted(s.arrival) : hasPassed(s));

export const stopDelay = (s: Stop) => rowDelay(s.departure) ?? rowDelay(s.arrival);

const sortTime = (s: Stop) => s.arrival?.advertisedTime ?? s.departure?.advertisedTime;

/** `TrainJourney.buildStops`. */
export function buildStops(rows: Announcement[]): Stop[] {
  const byStation = new Map<string, Stop>();
  for (const row of rows) {
    if (!isPassengerActivity(row) || !row.locationSignature) {
      continue;
    }
    let stop = byStation.get(row.locationSignature);
    if (!stop) {
      stop = { signature: row.locationSignature };
      byStation.set(row.locationSignature, stop);
    }
    if (row.activityType === "arrival") {
      stop.arrival = row;
    } else if (row.activityType === "departure") {
      stop.departure = row;
    }
  }
  for (const row of rows) {
    if (isPassengerActivity(row) || !row.locationSignature) {
      continue;
    }
    const stop = byStation.get(row.locationSignature);
    if (!stop) {
      continue;
    }
    if (row.activityType === "arrival" && !stop.arrival) {
      stop.arrival = row;
    } else if (row.activityType === "departure" && !stop.departure) {
      stop.departure = row;
    }
  }
  return [...byStation.values()].sort((l, r) => {
    const a = sortTime(l);
    const b = sortTime(r);
    if (a !== undefined && b !== undefined) {
      return a < b ? -1 : a > b ? 1 : 0;
    }
    if (a === undefined && b !== undefined) {
      return 1;
    }
    if (a !== undefined && b === undefined) {
      return -1;
    }
    return 0;
  });
}

export function buildJourney(rows: Announcement[]): Journey {
  return { stops: buildStops(rows), rows };
}

export function journeyProductName(journey: Journey): string | undefined {
  const representative =
    journey.rows.find((r) => r.activityType === "departure" && isPassengerActivity(r)) ?? journey.rows[0];
  return representative && displayProduct(representative);
}

/** The latest place the train was reported at, passing points included. First of equals wins, like `max(by:)`. */
export function lastReport(journey: Journey): { signature: string; time: number } | undefined {
  let latest: { signature: string; time: number } | undefined;
  for (const row of journey.rows) {
    if (row.locationSignature && row.actualTime !== undefined && (!latest || latest.time < row.actualTime)) {
      latest = { signature: row.locationSignature, time: row.actualTime };
    }
  }
  return latest;
}

export function latestModified(journey: Journey): number | undefined {
  let latest: number | undefined;
  for (const row of journey.rows) {
    if (row.modifiedTime !== undefined && (latest === undefined || row.modifiedTime > latest)) {
      latest = row.modifiedTime;
    }
  }
  return latest;
}

export type Status = "scheduled" | "enRoute" | "arrived" | "canceled";

export function journeyStatus(journey: Journey): Status {
  const { stops } = journey;
  if (stops.length > 0 && stops.every(stopIsCanceled)) {
    return "canceled";
  }
  const destination = stops[stops.length - 1];
  if (destination && hasArrived(destination)) {
    return "arrived";
  }
  return stops.some(hasPassed) ? "enRoute" : "scheduled";
}
