import type { Status } from "./journey.js";
import type { Snapshot } from "./snapshot.js";
import { swiftDate } from "./time.js";
import type { Station } from "./trafikverket.js";

// Port of `TrainActivityAttributes.ContentState(snapshot:names:)` and the cadence in
// `LiveActivityController`. ActivityKit decodes `content-state` into that struct with a default
// `JSONDecoder`, so dates go out as seconds since 2001-01-01 and every non-optional field is required.

export interface UpcomingStopState {
  name: string;
  expected?: number;
  track?: string;
}

/** Times are epoch ms here; `encode` converts them. */
export interface ContentState {
  status: Status;
  delaySeconds?: number;
  nextStopName?: string;
  nextStopPlanned?: number;
  nextStopExpected?: number;
  nextStopTrack?: string;
  lastPassedName?: string;
  lastPassedTime?: number;
  expectedDeparture?: number;
  expectedArrival?: number;
  originTrack?: string;
  originName?: string;
  destinationName?: string;
  scheduledDeparture?: number;
  scheduledArrival?: number;
  progress: number;
  updatedAt: number;
  upcoming: UpcomingStopState[];
}

/** `StationNames`: signatures to display names, falling back to the signature itself. */
export class StationNames {
  constructor(private readonly stations: Map<string, Station> = new Map()) {}

  name(signature: string | undefined): string {
    if (signature === undefined) {
      return "–";
    }
    return this.stations.get(signature)?.name ?? signature;
  }

  shortName(signature: string | undefined): string {
    if (signature === undefined) {
      return "–";
    }
    const station = this.stations.get(signature);
    return station?.shortName ?? station?.name ?? signature;
  }
}

export function contentState(snapshot: Snapshot, names: StationNames, now: number): ContentState {
  return {
    status: snapshot.status ?? "scheduled",
    delaySeconds: snapshot.delay === undefined ? undefined : Math.trunc(snapshot.delay),
    nextStopName: snapshot.nextStopSignature === undefined ? undefined : names.shortName(snapshot.nextStopSignature),
    nextStopPlanned: snapshot.nextStopPlanned,
    nextStopExpected: snapshot.nextStopExpected,
    nextStopTrack: snapshot.nextStopTrack,
    lastPassedName: snapshot.lastPassedSignature === undefined ? undefined : names.shortName(snapshot.lastPassedSignature),
    lastPassedTime: snapshot.lastPassedTime,
    expectedDeparture: snapshot.expectedDeparture,
    expectedArrival: snapshot.expectedArrival,
    originTrack: snapshot.originTrack,
    originName: names.name(snapshot.originSignature),
    destinationName: names.name(snapshot.destinationSignature),
    scheduledDeparture: snapshot.scheduledDeparture,
    scheduledArrival: snapshot.scheduledArrival,
    progress: snapshot.progress,
    updatedAt: snapshot.updatedAt ?? now,
    upcoming: snapshot.upcomingStops.slice(0, 3).map((s) => ({
      name: names.shortName(s.signature),
      expected: s.expected,
      track: s.track,
    })),
  };
}

const dateFields = [
  "nextStopPlanned",
  "nextStopExpected",
  "lastPassedTime",
  "expectedDeparture",
  "expectedArrival",
  "scheduledDeparture",
  "scheduledArrival",
  "updatedAt",
] as const;

/** The JSON ActivityKit decodes. Absent optionals are left out, as `JSONEncoder` does. */
export function encode(state: ContentState): Record<string, unknown> {
  const out: Record<string, unknown> = { ...state };
  for (const field of dateFields) {
    const value = state[field];
    out[field] = value === undefined ? undefined : swiftDate(value);
  }
  out.upcoming = state.upcoming.map((s) => ({ ...s, expected: s.expected === undefined ? undefined : swiftDate(s.expected) }));
  return JSON.parse(JSON.stringify(out)) as Record<string, unknown>;
}

const minute = 60_000;

/** How soon to look at a train in this state again; undefined once there is nothing left to follow. */
export function refreshInterval(state: ContentState, now: number): number | undefined {
  switch (state.status) {
    case "arrived":
    case "canceled":
      return undefined;
    case "enRoute":
      return minute;
    case "scheduled": {
      const untilDeparture = (state.expectedDeparture ?? Number.POSITIVE_INFINITY) - now;
      if (untilDeparture < 45 * minute) {
        return 3 * minute;
      }
      return Math.min(Math.max(untilDeparture / 4, 10 * minute), 60 * minute);
    }
  }
}

/** When the activity should dim if no newer state arrives: a few refresh intervals out. */
export function staleDate(state: ContentState, now: number): number {
  const interval = refreshInterval(state, now) ?? 20 * minute;
  return now + Math.max(interval * 3, 5 * minute);
}
