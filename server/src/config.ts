import { timingSafeEqual } from "node:crypto";
import { parseApnsKeys, type ApnsKeyConfig } from "./apns.js";

// Environment variables, set in the Vercel project (see docs/live-activity-push.md).

export interface Config {
  trafikverketApiKey: string;
  apnsKeys: ApnsKeyConfig[];
  /** Shared with the app (`PUSH_SERVER_SECRET` in Config/Secrets.xcconfig). */
  appSecret: string;
  /** Sent by the scheduler that calls /api/tick. */
  cronSecret: string;
  /** Upper bound on stored activities, so the tick's work stays bounded whatever is registered. */
  maxActivities: number;
  /** Registration requests one client address may make per hour. */
  registrationsPerHour: number;
}

function required(env: NodeJS.ProcessEnv, name: string): string {
  const value = env[name];
  if (!value) {
    throw new Error(`${name} is not set`);
  }
  return value;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  return {
    trafikverketApiKey: required(env, "TRV_API_KEY"),
    // Optional: without keys no bundle ID is accepted, so the app keeps its activities local.
    apnsKeys: parseApnsKeys(env.APNS_KEYS),
    appSecret: required(env, "APP_SECRET"),
    cronSecret: required(env, "CRON_SECRET"),
    maxActivities: positiveInteger(env, "MAX_ACTIVITIES", 2000),
    // Generous: a phone sends about two an hour, and carrier NAT puts many phones behind one address.
    registrationsPerHour: positiveInteger(env, "REGISTRATIONS_PER_HOUR", 300),
  };
}

function positiveInteger(env: NodeJS.ProcessEnv, name: string, fallback: number): number {
  const raw = env[name];
  if (raw === undefined || raw === "") {
    return fallback;
  }
  const value = Number(raw);
  if (!Number.isInteger(value) || value < 1) {
    throw new Error(`${name} must be a positive integer`);
  }
  return value;
}

/**
 * The caller's address as Vercel's edge reports it (it overwrites these headers), for rate limiting.
 * IPv6 is reduced to its /64, which one subscriber usually holds whole.
 */
export function clientAddress(request: Request): string {
  const forwarded = request.headers.get("x-forwarded-for")?.split(",")[0]?.trim();
  const address = request.headers.get("x-real-ip") ?? forwarded ?? "unknown";
  return address.includes(":") ? `${ipv6Groups(address).slice(0, 4).join(":")}::/64` : address;
}

function ipv6Groups(address: string): string[] {
  const [head = "", tail] = address.split("::");
  const left = head ? head.split(":") : [];
  const right = tail ? tail.split(":") : [];
  const missing = tail === undefined ? 0 : 8 - left.length - right.length;
  return [...left, ...Array<string>(Math.max(missing, 0)).fill("0"), ...right].map((g) => g.toLowerCase().replace(/^0+(?=.)/, ""));
}

/** Constant-time check of `Authorization: Bearer <secret>`. */
export function authorized(request: Request, secret: string): boolean {
  const header = request.headers.get("authorization") ?? "";
  const expected = Buffer.from(`Bearer ${secret}`);
  const actual = Buffer.from(header);
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

export function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

/** Logs the cause and answers without leaking it. */
export function serverError(error: unknown): Response {
  console.error(JSON.stringify({ msg: "request failed", error: error instanceof Error ? error.message : String(error) }));
  return json(500, { error: "internal" });
}
