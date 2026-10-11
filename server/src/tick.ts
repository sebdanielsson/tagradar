import { createHash } from "node:crypto";
import { alertBody, alertTitle, evaluate, type AlertKind } from "./alerts.js";
import type { ApnsEnvironment, LiveActivityPush, PushResult, PushSender } from "./apns.js";
import { contentState, encode, refreshInterval, staleDate, type StationNames } from "./contentState.js";
import { buildJourney, type Journey } from "./journey.js";
import { snapshot } from "./snapshot.js";
import type { Activity, ActivityState, Settlement, Store } from "./store.js";
import { dayStart } from "./time.js";
import { parseTrainKey, type Announcement, type JourneyFetcher, type TrainKey } from "./trafikverket.js";

// One pass, run every minute by an external scheduler: claim the runs that are due, load them in
// one Trafikverket request, push the activities whose state changed, end the ones that are done and
// decide when to look at each run again.

const minute = 60_000;
/** Bounds one tick's work (and its share of the free tier); the rest waits for the next tick. */
const maxTrainsPerTick = 40;
/** Claimed runs are skipped by overlapping ticks for this long. */
const lease = 3 * minute;
/** How long a finished activity stays on the Lock Screen, like `LiveActivityController.update`. */
const dismissAfter = 15 * minute;
/** A run that should have arrived this long ago is ended even if its arrival was never reported. */
const overdueAfter = 60 * minute;
const retryAfterError = 2 * minute;
const retryMissingJourney = 5 * minute;
/** Failed pushes (APNs trouble, not a dead token) are retried with growing gaps up to this. */
const maxRetryInterval = 15 * minute;

export interface TickDeps {
  store: Store;
  fetchJourneys: JourneyFetcher;
  names: () => Promise<StationNames>;
  push: PushSender;
  now: number;
}

export interface TickStats {
  due: number;
  activities: number;
  pushed: number;
  alerts: number;
  ended: number;
  removed: number;
  failed: number;
  error?: string;
}

type Outcome = { kind: "keep"; state: ActivityState; interval: number } | { kind: "remove" };

const other = (environment: ApnsEnvironment): ApnsEnvironment => (environment === "production" ? "development" : "production");

const hash = (value: unknown) => createHash("sha1").update(JSON.stringify(value)).digest("base64url");

const message = (error: unknown) => (error instanceof Error ? error.message : String(error));

export async function tick(deps: TickDeps): Promise<TickStats> {
  const { store, now } = deps;
  const stats: TickStats = { due: 0, activities: 0, pushed: 0, alerts: 0, ended: 0, removed: 0, failed: 0 };
  const claims = await store.claimDue(now, maxTrainsPerTick, now + lease);
  stats.due = claims.length;
  if (claims.length === 0) {
    return stats;
  }
  const settlements: Settlement[] = [];
  const settle = (trainId: string, next: number | null) => settlements.push({ trainId, lease: now + lease, next });

  const byTrain = await store.activitiesFor(claims.map((c) => c.trainId));
  const keys: TrainKey[] = [];
  for (const { trainId } of claims) {
    const key = parseTrainKey(trainId);
    if (key && (byTrain.get(trainId)?.length ?? 0) > 0) {
      keys.push(key);
    } else {
      settle(trainId, null);
    }
  }

  let journeys = new Map<string, Announcement[]>();
  try {
    journeys = await deps.fetchJourneys(keys);
  } catch (error) {
    stats.error = message(error);
    for (const key of keys) {
      settle(key.id, now + retryAfterError);
    }
    keys.length = 0;
  }
  const names = keys.length > 0 ? await deps.names() : undefined;

  // Saved right after each activity's push, not at the end: a tick cut short must not leave
  // delivered alerts unrecorded, or the next tick would send them again.
  const persist = async (activity: Activity, outcome: Outcome) => {
    if (outcome.kind === "remove") {
      stats.removed += 1;
      await store.removeIfToken([activity.registration]);
    } else if (JSON.stringify(outcome.state) !== JSON.stringify(activity.state)) {
      await store.saveStates([{ id: activity.registration.id, state: outcome.state }]);
    }
  };

  await Promise.all(
    keys.map(async (key) => {
      try {
        const activities = byTrain.get(key.id) ?? [];
        stats.activities += activities.length;
        const rows = journeys.get(key.id) ?? [];
        const start = dayStart(key.day) ?? now;
        if (rows.length === 0) {
          // Not published yet, or gone. Give up two days after the run's date.
          if (now > start + 48 * 60 * minute) {
            stats.removed += activities.length;
            await store.removeIfToken(activities.map((a) => a.registration));
            settle(key.id, null);
          } else {
            settle(key.id, now + retryMissingJourney);
          }
          return;
        }
        const journey = buildJourney(rows);
        const intervals = await Promise.all(
          activities.map(async (activity) => {
            const outcome = await follow(activity, key, journey, start, names!, deps, stats);
            await persist(activity, outcome);
            return outcome.kind === "keep" ? outcome.interval : Number.POSITIVE_INFINITY;
          }),
        );
        const next = Math.min(...intervals);
        settle(key.id, Number.isFinite(next) ? now + next : null);
      } catch (error) {
        // One bad run must not hold up the others; it is tried again shortly.
        stats.error = message(error);
        settle(key.id, now + retryAfterError);
      }
    }),
  );

  await store.settle(settlements, now);
  return stats;
}

/** Works out one activity's state, pushes it if needed and says what to keep. */
async function follow(
  activity: Activity,
  key: TrainKey,
  journey: Journey,
  runStart: number,
  names: StationNames,
  deps: TickDeps,
  stats: TickStats,
): Promise<Outcome> {
  const { now } = deps;
  const { registration } = activity;
  const segmentKey = JSON.stringify(registration.segment ?? null);
  // A state built for other stops (the segment changed mid-tick) is a fresh start.
  const previous: ActivityState = activity.state?.segmentKey === segmentKey ? activity.state : { segmentKey };
  // Backing off after failed pushes. Nothing is evaluated meanwhile, so no alert is used up unsent.
  if (previous.retryAt !== undefined && now < previous.retryAt) {
    return { kind: "keep", state: previous, interval: previous.retryAt - now };
  }
  const state: ActivityState = structuredClone(previous);

  const snap = snapshot(key.ident, journey, registration.segment);
  const content = contentState(snap, names, now);
  const encoded = encode(content);
  const stateHash = hash(encoded);

  // Alerts a failed push left over go first.
  let alerts: AlertKind[] = registration.alerts ? (state.pendingAlerts ?? []) : [];
  state.pendingAlerts = undefined;
  if (registration.alerts) {
    const result = evaluate(state.alertState, snap);
    alerts = [...alerts, ...result.alerts];
    state.alertState = result.state;
  }

  const arrival = content.expectedArrival ?? content.scheduledArrival ?? runStart + 36 * 60 * minute;
  const finished = content.status === "arrived" || content.status === "canceled" || now > arrival + overdueAfter;
  const interval = refreshInterval(content, now) ?? minute;
  const stale = staleDate(content, now);
  const refreshDue = state.lastStaleAt === undefined || now >= state.lastStaleAt - Math.max(interval, 2 * minute);
  if (!finished && alerts.length === 0 && stateHash === state.lastHash && !refreshDue) {
    return { kind: "keep", state, interval };
  }

  const seconds = (ms: number) => Math.floor(ms / 1000);
  // One alert per push, so a delay and a track change in the same poll are both told; the
  // content is the same each time. Without alerts, one push.
  // Each push a second later than the one before, so ActivityKit takes every one as newer.
  // Only the last push of a finished run ends the activity, so the alerts before it still show.
  const payloads = (alerts.length > 0 ? alerts : [undefined]).map((alert, i, all) => ({
    aps: {
      timestamp: seconds(now) + i,
      event: finished && i === all.length - 1 ? "end" : "update",
      "content-state": encoded,
      "stale-date": seconds(stale),
      ...(finished ? { "dismissal-date": seconds(now + dismissAfter) } : {}),
      ...(alert ? { alert: { title: alertTitle(snap), body: alertBody(alert, snap, names), sound: "default" } } : {}),
    },
  }));
  // Priority 10 is shown at once but budgeted; routine progress goes at 5.
  const important =
    alerts.length > 0 || finished || content.status !== state.lastStatus || content.nextStopName !== state.lastNextStop;
  let environment = state.environment ?? registration.environment;

  let result: PushResult = { status: 0 };
  let delivered = 0;
  for (const payload of payloads) {
    const push: LiveActivityPush = {
      token: registration.token,
      bundleId: registration.bundleId,
      environment,
      priority: important ? 10 : 5,
      payload,
    };
    result = await deps.push.send(push);
    if (result.status === 400 && result.reason === "BadDeviceToken") {
      // A Release build run from Xcode still gets sandbox tokens, and the other way around.
      const retry = await deps.push.send({ ...push, environment: other(environment) });
      if (retry.status === 200) {
        environment = other(environment);
        state.environment = environment;
      }
      result = retry;
    }
    if (result.status !== 200) {
      break;
    }
    delivered += 1;
  }
  stats.pushed += delivered;
  stats.alerts += Math.min(delivered, alerts.length);

  if (result.status === 200) {
    if (finished) {
      stats.ended += 1;
      return { kind: "remove" };
    }
    state.lastHash = stateHash;
    state.lastStaleAt = stale;
    state.lastStatus = content.status;
    state.lastNextStop = content.nextStopName;
    state.failures = undefined;
    state.retryAt = undefined;
    return { kind: "keep", state, interval };
  }
  if (result.status === 410 || result.reason === "BadDeviceToken" || result.reason === "Unregistered") {
    // The activity ended on the phone or the token is no longer valid.
    return { kind: "remove" };
  }
  // Anything else (throttling, APNs trouble, a broken key): try again later, with growing gaps, and
  // never give up before the registration expires — an outage must not cost every activity.
  stats.failed += 1;
  console.error(JSON.stringify({ msg: "push failed", activity: registration.id, status: result.status, reason: result.reason }));
  const failures = (previous.failures ?? 0) + 1;
  const retryIn = Math.min(interval, retryAfterError) * 2 ** Math.min(failures - 1, 4);
  // Alerts that went out are recorded; the rest wait for the next attempt. Nothing went out: the
  // previous state stands and the alerts are evaluated again.
  const wait = Math.min(retryIn, maxRetryInterval);
  const retryState: ActivityState =
    delivered > 0
      ? { ...state, pendingAlerts: alerts.slice(delivered), failures, retryAt: now + wait }
      : { ...previous, failures, retryAt: now + wait };
  return { kind: "keep", state: retryState, interval: wait };
}
