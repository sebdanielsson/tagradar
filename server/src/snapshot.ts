import {
  arrivalTrack,
  bestKnownTime,
  hasArrived,
  hasPassed,
  journeyProductName,
  journeyStatus,
  lastReport,
  latestModified,
  rowDelay,
  stopDelay,
  stopIsCanceled,
  stopTrack,
  type Journey,
  type Status,
  type Stop,
} from "./journey.js";

// Port of `TrainSnapshot(journey:segment:)` and `TripSegment.range(in:)`. Every live field is relative
// to the user's segment, so delays outside it never reach the activity or an alert.

export interface Segment {
  boarding?: string;
  alighting?: string;
}

export interface UpcomingStop {
  signature: string;
  expected?: number;
  track?: string;
}

export interface Snapshot {
  ident: string;
  productName?: string;
  originSignature?: string;
  destinationSignature?: string;
  scheduledDeparture?: number;
  scheduledArrival?: number;
  status?: Status;
  /** Seconds late. */
  delay?: number;
  expectedDeparture?: number;
  expectedArrival?: number;
  originTrack?: string;
  nextStopSignature?: string;
  nextStopPlanned?: number;
  nextStopExpected?: number;
  nextStopTrack?: string;
  lastPassedSignature?: string;
  lastPassedTime?: number;
  progress: number;
  updatedAt?: number;
  upcomingStops: UpcomingStop[];
}

/** `TripSegment.range(in:)`, with a missing segment meaning the whole run. */
export function segmentRange(segment: Segment | null | undefined, stops: Stop[]): [number, number] | undefined {
  if (stops.length === 0) {
    return undefined;
  }
  let first = 0;
  let last = stops.length - 1;
  if (segment?.boarding) {
    const i = stops.findIndex((s) => s.signature === segment.boarding);
    first = i >= 0 ? i : 0;
  }
  if (segment?.alighting) {
    const i = stops.findLastIndex((s) => s.signature === segment.alighting);
    last = i >= 0 ? i : stops.length - 1;
  }
  return first <= last ? [first, last] : [0, stops.length - 1];
}

export function snapshot(ident: string, journey: Journey, segment?: Segment | null): Snapshot {
  const result: Snapshot = { ident, productName: journeyProductName(journey), progress: 0, upcomingStops: [] };
  const range = segmentRange(segment, journey.stops);
  if (!range) {
    result.status = journeyStatus(journey);
    result.updatedAt = latestModified(journey);
    return result;
  }
  const part = journey.stops.slice(range[0], range[1] + 1);
  const first = part[0];
  const last = part[part.length - 1];
  result.originSignature = first?.signature;
  result.destinationSignature = last?.signature;
  // The boarding stop's departure, or its arrival at a drop-off-only stop; the alighting stop's arrival.
  const departureRow = first?.departure ?? first?.arrival;
  const arrivalRow = last?.arrival ?? last?.departure;
  result.scheduledDeparture = departureRow?.advertisedTime;
  result.scheduledArrival = arrivalRow?.advertisedTime;
  result.expectedDeparture = bestKnownTime(departureRow);
  result.expectedArrival = bestKnownTime(arrivalRow);
  result.originTrack = first && stopTrack(first);

  const boarded = first ? hasPassed(first) : false;
  const done = last ? hasArrived(last) : false;
  if (part.every(stopIsCanceled) || (first && stopIsCanceled(first)) || (last && stopIsCanceled(last))) {
    result.status = "canceled";
  } else if (done) {
    result.status = "arrived";
  } else if (boarded) {
    result.status = "enRoute";
  } else {
    result.status = "scheduled";
  }

  const remaining = part.filter((s) => !hasPassed(s) && !stopIsCanceled(s));
  const next = remaining[0];
  result.upcomingStops = remaining.slice(1, 5).map((s) => ({
    signature: s.signature,
    expected: bestKnownTime(s.arrival) ?? bestKnownTime(s.departure),
    track: arrivalTrack(s),
  }));
  result.nextStopSignature = boarded ? next?.signature : undefined;
  result.nextStopPlanned = next?.arrival?.advertisedTime ?? next?.departure?.advertisedTime;
  result.nextStopExpected = bestKnownTime(next?.arrival) ?? bestKnownTime(next?.departure);
  result.nextStopTrack = next && arrivalTrack(next);
  switch (result.status) {
    case "scheduled":
      result.delay = rowDelay(departureRow);
      break;
    case "enRoute": {
      const lastPassed = part.findLast(hasPassed);
      result.delay = rowDelay(next?.arrival) ?? rowDelay(next?.departure) ?? (lastPassed && stopDelay(lastPassed));
      break;
    }
    case "arrived":
      result.delay = rowDelay(arrivalRow);
      break;
    default:
      result.delay = undefined;
  }
  // Reports from before the boarding stop are still useful context ("passed X 12:55").
  const report = lastReport(journey);
  result.lastPassedSignature = report?.signature;
  result.lastPassedTime = report?.time;
  const total = part.length;
  const passed = part.filter(hasPassed).length;
  result.progress = total > 1 ? Math.min(1, passed / (total - 1)) : done ? 1 : 0;
  result.updatedAt = latestModified(journey);
  return result;
}

/** `TrainSnapshot.isCanceled`. */
export const isCanceled = (s: Snapshot) => s.status === "canceled";
