import type { ApnsEnvironment } from "./apns.js";
import type { Segment } from "./snapshot.js";
import type { Registration, Store } from "./store.js";
import { dayStart } from "./time.js";
import { parseTrainKey } from "./trafikverket.js";

// POST /api/activities: the app registers (or updates) a followed train's activity.

const day = 24 * 60 * 60_000;

export interface RegistrationInput {
  activityId: string;
  token: string;
  trainId: string;
  bundleId: string;
  environment: ApnsEnvironment;
  segment: Segment | null;
  alerts: boolean;
}

export type Validated = { ok: true; value: RegistrationInput; runStart: number } | { ok: false; error: string };

// Trafikverket signatures: letters (å, ä, ö), digits, and the odd space or dot ("Gä.f").
const signature = /^[\p{L}\p{N} .]{1,12}$/u;

export function validate(body: unknown, bundleIds: string[], now: number): Validated {
  if (typeof body !== "object" || body === null) {
    return { ok: false, error: "body must be a JSON object" };
  }
  const b = body as Record<string, unknown>;
  if (typeof b.activityId !== "string" || !/^[A-Za-z0-9-]{1,64}$/.test(b.activityId)) {
    return { ok: false, error: "activityId" };
  }
  if (typeof b.token !== "string" || !/^[0-9a-fA-F]{32,512}$/.test(b.token)) {
    return { ok: false, error: "token" };
  }
  const key = typeof b.trainId === "string" ? parseTrainKey(b.trainId) : undefined;
  const runStart = key && dayStart(key.day);
  // Today's and tomorrow's runs, and yesterday's still running past midnight.
  if (!key || runStart === undefined || runStart < now - 2 * day || runStart > now + 2 * day) {
    return { ok: false, error: "trainId" };
  }
  if (typeof b.bundleId !== "string" || !bundleIds.includes(b.bundleId)) {
    return { ok: false, error: "bundleId" };
  }
  if (b.environment !== "development" && b.environment !== "production") {
    return { ok: false, error: "environment" };
  }
  let segment: Segment | null = null;
  if (b.segment !== undefined && b.segment !== null) {
    const s = b.segment as Record<string, unknown>;
    const valid = (v: unknown) => v === undefined || v === null || (typeof v === "string" && signature.test(v));
    if (typeof s !== "object" || !valid(s.boarding) || !valid(s.alighting)) {
      return { ok: false, error: "segment" };
    }
    segment = {
      ...(typeof s.boarding === "string" ? { boarding: s.boarding } : {}),
      ...(typeof s.alighting === "string" ? { alighting: s.alighting } : {}),
    };
  }
  return {
    ok: true,
    runStart,
    value: {
      activityId: b.activityId,
      token: b.token.toLowerCase(),
      trainId: key.id,
      bundleId: b.bundleId,
      environment: b.environment,
      segment,
      alerts: b.alerts === true,
    },
  };
}

/** Stores the registration. The tick's state for it survives a new token or alert choice, not new stops. */
export async function register(
  store: Store,
  input: RegistrationInput,
  runStart: number,
  now: number,
  maxActivities: number,
): Promise<{ status: number; error?: string }> {
  const existing = await store.get(input.activityId);
  if (!existing && (await store.count(now)) >= maxActivities) {
    return { status: 503, error: "capacity" };
  }
  const sameRun = existing?.trainId === input.trainId;
  const sameSegment = JSON.stringify(existing?.segment ?? null) === JSON.stringify(input.segment);
  const registration: Registration = {
    id: input.activityId,
    trainId: input.trainId,
    token: input.token,
    bundleId: input.bundleId,
    environment: input.environment,
    segment: input.segment,
    alerts: input.alerts,
    createdAt: existing?.createdAt ?? now,
  };
  if (existing && !sameRun) {
    await store.remove([existing]);
  }
  // Kept until three days after the run's date; the tick removes it long before that.
  const ttlSeconds = Math.max(3600, Math.ceil((runStart + 3 * day - now) / 1000));
  // A new segment means a new baseline: what was said about the old stops does not carry over.
  await store.register(registration, { ttlSeconds, now, resetState: !sameRun || !sameSegment });
  return { status: 204 };
}
