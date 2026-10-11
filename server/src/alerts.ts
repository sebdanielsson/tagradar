import type { Snapshot } from "./snapshot.js";
import { isCanceled } from "./snapshot.js";
import type { StationNames } from "./contentState.js";
import { clock } from "./time.js";

// Port of `TrainAlertEngine`, for followed trains whose alerts now ride on the Live Activity push.
// Alert texts go out as `loc-key`s from Localizable.xcstrings, so the phone shows them in its own
// language; every argument is a string, so the keys use `%@` only.

export interface AlertState {
  delayMinutes?: number;
  canceled: boolean;
  track?: string;
  arrived: boolean;
  boarded: boolean;
}

export type AlertKind =
  | { kind: "delay"; minutes: number }
  | { kind: "backOnTime" }
  | { kind: "canceled" }
  | { kind: "trackChanged"; from: string; to: string }
  | { kind: "arrived"; delayMinutes?: number };

/** Delay changes smaller than this (in minutes) are not worth a notification. */
export const delayThresholdMinutes = 5;

/** Swift's `.rounded()`: half away from zero. */
const roundHalfAway = (x: number) => Math.sign(x) * Math.round(Math.abs(x));

export function evaluate(previous: AlertState | undefined, current: Snapshot): { alerts: AlertKind[]; state: AlertState } {
  const minutes = current.delay === undefined ? undefined : roundHalfAway(current.delay / 60);
  const arrived = current.status === "arrived";
  const state: AlertState = {
    delayMinutes: minutes,
    canceled: isCanceled(current),
    track: current.originTrack,
    arrived,
    boarded: current.status === "enRoute" || arrived,
  };
  if (!previous) {
    return { alerts: [], state };
  }
  // Nothing after the user's alighting station.
  if (previous.arrived) {
    return { alerts: [], state: previous };
  }
  const alerts: AlertKind[] = [];
  if (state.canceled && !previous.canceled) {
    alerts.push({ kind: "canceled" });
  }
  if (arrived) {
    alerts.push({ kind: "arrived", delayMinutes: minutes });
  }
  if (!state.canceled && !arrived) {
    if (minutes !== undefined) {
      const reference = previous.delayMinutes ?? 0;
      if (Math.abs(minutes - reference) >= delayThresholdMinutes) {
        if (minutes >= delayThresholdMinutes) {
          alerts.push({ kind: "delay", minutes });
        } else if (reference >= delayThresholdMinutes) {
          alerts.push({ kind: "backOnTime" });
        }
      } else {
        state.delayMinutes = previous.delayMinutes;
      }
    } else {
      state.delayMinutes = previous.delayMinutes;
    }
    if (!previous.boarded && previous.track !== undefined && state.track !== undefined && previous.track !== state.track) {
      alerts.push({ kind: "trackChanged", from: previous.track, to: state.track });
    }
  }
  if (previous.canceled && !state.canceled) {
    // Un-cancellations are rare enough to just tell the user the current delay next time.
    state.delayMinutes = undefined;
  }
  return { alerts, state };
}

export interface LocalizedText {
  "loc-key": string;
  "loc-args": string[];
}

const text = (key: string, ...args: string[]): LocalizedText => ({ "loc-key": key, "loc-args": args });

/** `TrainAlerts.body(for:snapshot:names:)`, as one key per variant. */
export function alertBody(alert: AlertKind, s: Snapshot, names: StationNames): LocalizedText {
  switch (alert.kind) {
    case "delay": {
      const minutes = String(alert.minutes);
      const departure = s.expectedDeparture ?? s.scheduledDeparture;
      const nextTime = s.nextStopExpected ?? s.nextStopPlanned;
      const arrival = s.expectedArrival ?? s.scheduledArrival;
      if (s.status === "scheduled" && departure !== undefined) {
        return text("Now %@ min late. New departure %@ from %@.", minutes, clock(departure), names.shortName(s.originSignature));
      }
      if (s.nextStopSignature !== undefined && nextTime !== undefined) {
        return text("Now %@ min late. Next %@ %@.", minutes, names.shortName(s.nextStopSignature), clock(nextTime));
      }
      if (arrival !== undefined) {
        return text("Now %@ min late. Arrives %@.", minutes, clock(arrival));
      }
      return text("Now %@ min late.", minutes);
    }
    case "backOnTime": {
      const arrival = s.expectedArrival ?? s.scheduledArrival;
      return arrival === undefined
        ? text("Back on time.")
        : text("Back on time. Arrives %@ %@.", names.shortName(s.destinationSignature), clock(arrival));
    }
    case "canceled":
      return text("The train is canceled. Check the operator's app for replacement traffic.");
    case "trackChanged":
      return text("Track changed from %@ to %@ at %@.", alert.from, alert.to, names.shortName(s.originSignature));
    case "arrived": {
      const when = clock(s.expectedArrival ?? s.scheduledArrival);
      const where = names.shortName(s.destinationSignature);
      if (alert.delayMinutes !== undefined && alert.delayMinutes >= 1) {
        return text("Arrived %@ %@, %@ min late.", where, when, String(alert.delayMinutes));
      }
      return text("Arrived %@ %@, on time.", where, when);
    }
  }
}

/** "SJ Snabbtåg 537" or "Train 537", like `TrainSnapshot.displayName`. */
export function alertTitle(s: Snapshot): LocalizedText {
  return s.productName ? text("%@ %@", s.productName, s.ident) : text("Train %@", s.ident);
}
