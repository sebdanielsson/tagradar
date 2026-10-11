import { readFileSync } from "node:fs";
import { join } from "node:path";
import { beforeEach, describe, expect, it } from "vitest";
import type { LiveActivityPush, PushResult, PushSender } from "../src/apns.js";
import { StationNames } from "../src/contentState.js";
import { register, validate } from "../src/registration.js";
import { MemoryStore } from "../src/store.js";
import { dismissal, tick } from "../src/tick.js";
import { clientAddress } from "../src/config.js";
import { parseAnnouncements, type Announcement } from "../src/trafikverket.js";

const fixture = (name: string) =>
  JSON.parse(readFileSync(join(import.meta.dirname, "fixtures", "contract", `${name}.json`), "utf8")) as {
    trainId: string;
    now: string;
    response: { RESPONSE: { RESULT: Record<string, unknown>[] } };
  };

const rowsOf = (name: string) => parseAnnouncements(fixture(name).response.RESPONSE.RESULT[0]);

class FakePush implements PushSender {
  sent: LiveActivityPush[] = [];
  results: PushResult[] = [];
  async send(push: LiveActivityPush) {
    this.sent.push(push);
    return this.results.shift() ?? { status: 200 };
  }
  close() {}
}

const token = "ab".repeat(32);
const now = Date.parse("2026-09-05T08:35:00Z");

async function follow(store: MemoryStore, id: string, body: Record<string, unknown> = {}) {
  const v = validate(
    { activityId: id, token, trainId: "837@2026-09-05", bundleId: "se.tagradar.app", environment: "production", alerts: true, ...body },
    ["se.tagradar.app"],
    now,
  );
  if (!v.ok) {
    throw new Error(v.error);
  }
  await register(store, v.value, v.runStart, now, 10);
}

describe("tick", () => {
  let store: MemoryStore;
  let push: FakePush;
  let rows: Announcement[];
  const run = (at: number) =>
    tick({ store, push, now: at, names: async () => new StationNames(), fetchJourneys: async (keys) => new Map(keys.map((k) => [k.id, rows])) });

  beforeEach(() => {
    store = new MemoryStore();
    push = new FakePush();
    rows = rowsOf("en-route-whole-run");
  });

  it("does nothing when nothing is due", async () => {
    expect(await run(now)).toMatchObject({ due: 0 });
    expect(push.sent).toEqual([]);
  });

  it("pushes the first state, then only changes and stale-date refreshes", async () => {
    await follow(store, "a1");
    const first = await run(now);
    expect(first).toMatchObject({ due: 1, activities: 1, pushed: 1 });
    const payload = push.sent[0]!.payload as { aps: Record<string, unknown> };
    expect(payload.aps.event).toBe("update");
    expect(payload.aps.timestamp).toBe(now / 1000);
    expect(payload.aps["content-state"]).toMatchObject({ status: "enRoute", nextStopName: "U" });
    expect(payload.aps.alert).toBeUndefined();
    expect(push.sent[0]!.priority).toBe(10);
    // En route: polled again a minute later, nothing changed, stale date still far off.
    expect(store.nextPoll.get("837@2026-09-05")).toBe(now + 60_000);
    await run(now + 60_000);
    expect(push.sent).toHaveLength(1);
    // Close to the stale date the same state goes out again, at low priority.
    await run(now + 4 * 60_000);
    expect(push.sent).toHaveLength(2);
    expect(push.sent[1]!.priority).toBe(5);
  });

  it("carries an alert when the delay grows", async () => {
    await follow(store, "a1");
    await run(now);
    rows = rows.map((r) => (r.locationSignature === "U" && r.activityType === "arrival" ? { ...r, estimatedTime: r.advertisedTime! + 20 * 60_000 } : r));
    const stats = await run(now + 60_000);
    expect(stats.alerts).toBe(1);
    const aps = (push.sent[1]!.payload as { aps: Record<string, unknown> }).aps;
    expect(aps.alert).toMatchObject({ body: { "loc-key": "Now %@ min late. Next %@ %@.", "loc-args": ["20", "U", "11:00"] }, sound: "default" });
    expect(push.sent[1]!.priority).toBe(10);
  });

  it("does not alert when the user turned alerts off", async () => {
    await follow(store, "a1", { alerts: false });
    await run(now);
    rows = rows.map((r) => (r.locationSignature === "U" && r.activityType === "arrival" ? { ...r, estimatedTime: r.advertisedTime! + 20 * 60_000 } : r));
    expect((await run(now + 60_000)).alerts).toBe(0);
  });

  it("ends the activity on arrival and forgets the run", async () => {
    await follow(store, "a1");
    rows = rowsOf("arrived");
    const stats = await run(now);
    expect(stats).toMatchObject({ ended: 1, removed: 1 });
    const aps = (push.sent[0]!.payload as { aps: Record<string, unknown> }).aps;
    expect(aps.event).toBe("end");
    // Five minutes after the arrival at 13:03 (#57).
    expect(aps["dismissal-date"]).toBe(Date.parse("2026-09-05T11:08:00Z") / 1000);
    expect(store.registrations.size).toBe(0);
    expect(store.nextPoll.size).toBe(0);
  });

  it("drops tokens APNs no longer accepts", async () => {
    await follow(store, "a1");
    push.results = [{ status: 410, reason: "Unregistered" }];
    await run(now);
    expect(store.registrations.size).toBe(0);
  });

  it("switches APNs environment when the token belongs to the other one", async () => {
    await follow(store, "a1");
    push.results = [{ status: 400, reason: "BadDeviceToken" }, { status: 200 }];
    await run(now);
    expect(push.sent.map((p) => p.environment)).toEqual(["production", "development"]);
    expect(store.states.get("a1")?.environment).toBe("development");
  });

  it("keeps the old record when a push fails, so an alert is not lost", async () => {
    await follow(store, "a1");
    push.results = [{ status: 429, reason: "TooManyRequests" }];
    const stats = await run(now);
    expect(stats.failed).toBe(1);
    expect(store.states.get("a1")?.lastHash).toBeUndefined();
    expect(store.states.get("a1")?.failures).toBe(1);
    expect(store.nextPoll.get("837@2026-09-05")).toBe(now + 60_000);
  });

  it("backs off when Trafikverket fails", async () => {
    await follow(store, "a1");
    const stats = await tick({
      store,
      push,
      now,
      names: async () => new StationNames(),
      fetchJourneys: async () => {
        throw new Error("Trafikverket: HTTP 503");
      },
    });
    expect(stats.error).toBe("Trafikverket: HTTP 503");
    expect(store.nextPoll.get("837@2026-09-05")).toBe(now + 120_000);
  });

  it("sends every alert of one poll, not just the first", async () => {
    rows = rowsOf("boarding-later");
    await follow(store, "a1", { segment: { boarding: "Gä" } });
    await run(now);
    // Before boarding: 15 min later and a new track at the same time.
    rows = rows.map((r) =>
      r.locationSignature === "Gä" && r.activityType === "departure" ? { ...r, estimatedTime: r.advertisedTime! + 15 * 60_000, trackAtLocation: "5" } : r,
    );
    const stats = await run(now + 60 * 60_000);
    expect(stats.alerts).toBe(2);
    const keys = push.sent.slice(1).map((p) => (p.payload as { aps: { alert: { body: { "loc-key": string } } } }).aps.alert.body["loc-key"]);
    expect(keys).toEqual(["Now %@ min late. New departure %@ from %@.", "Track changed from %@ to %@ at %@."]);
  });

  it("leases claimed runs so an overlapping tick skips them", async () => {
    await follow(store, "a1");
    let release!: () => void;
    const slow = tick({
      store,
      push,
      now,
      names: async () => new StationNames(),
      fetchJourneys: (keys) => new Promise((resolve) => (release = () => resolve(new Map(keys.map((k) => [k.id, rows]))))),
    });
    await new Promise((r) => setTimeout(r, 0));
    expect((await run(now + 60_000)).due).toBe(0);
    release();
    await slow;
    expect(push.sent).toHaveLength(1);
  });

  it("does not drop a run someone registered for during the tick", async () => {
    await follow(store, "a1");
    rows = rowsOf("arrived");
    let release!: () => void;
    const ending = tick({
      store,
      push,
      now,
      names: async () => new StationNames(),
      fetchJourneys: (keys) => new Promise((resolve) => (release = () => resolve(new Map(keys.map((k) => [k.id, rows]))))),
    });
    await new Promise((r) => setTimeout(r, 0));
    await follow(store, "a2");
    release();
    await ending;
    expect(store.registrations.has("a2")).toBe(true);
    expect(store.nextPoll.get("837@2026-09-05")).toBe(now);
  });

  it("never rewrites a registration, only its own state", async () => {
    await follow(store, "a1");
    let release!: () => void;
    const pending = tick({
      store,
      push,
      now,
      names: async () => new StationNames(),
      fetchJourneys: (keys) => new Promise((resolve) => (release = () => resolve(new Map(keys.map((k) => [k.id, rows]))))),
    });
    await new Promise((r) => setTimeout(r, 0));
    await follow(store, "a1", { token: "cd".repeat(32), alerts: false });
    release();
    await pending;
    expect(store.registrations.get("a1")).toMatchObject({ token: "cd".repeat(32), alerts: false });
  });

  it("backs off on failing pushes but keeps the activity", async () => {
    await follow(store, "a1");
    push.results = Array.from({ length: 20 }, () => ({ status: 500, reason: "InternalServerError" }));
    const gaps: number[] = [];
    let at = now;
    for (let i = 0; i < 7; i++) {
      await run(at);
      const next = store.nextPoll.get("837@2026-09-05")!;
      gaps.push((next - at) / 60_000);
      at = next;
    }
    expect(gaps).toEqual([1, 2, 4, 8, 15, 15, 15]);
    expect(store.registrations.has("a1")).toBe(true);
  });

  it("records alerts that went out when a later one fails, and sends the rest next time", async () => {
    rows = rowsOf("boarding-later");
    await follow(store, "a1", { segment: { boarding: "Gä" } });
    await run(now);
    rows = rows.map((r) =>
      r.locationSignature === "Gä" && r.activityType === "departure" ? { ...r, estimatedTime: r.advertisedTime! + 15 * 60_000, trackAtLocation: "5" } : r,
    );
    push.results = [{ status: 200 }, { status: 503, reason: "ServiceUnavailable" }];
    await run(now + 60 * 60_000);
    expect(store.states.get("a1")?.pendingAlerts).toEqual([{ kind: "trackChanged", from: "3", to: "5" }]);
    await run(now + 63 * 60_000);
    const keys = push.sent
      .map((p) => (p.payload as { aps: { alert?: { body: { "loc-key": string } } } }).aps.alert?.body["loc-key"])
      .filter(Boolean);
    // The delay once, the track change after its failed attempt, and nothing repeated.
    expect(keys).toEqual([
      "Now %@ min late. New departure %@ from %@.",
      "Track changed from %@ to %@ at %@.",
      "Track changed from %@ to %@ at %@.",
    ]);
    expect(push.results).toEqual([]);
    expect(store.states.get("a1")?.pendingAlerts).toBeUndefined();
  });

  it("gives each push of one poll a newer timestamp", async () => {
    rows = rowsOf("boarding-later");
    await follow(store, "a1", { segment: { boarding: "Gä" } });
    await run(now);
    rows = rows.map((r) =>
      r.locationSignature === "Gä" && r.activityType === "departure" ? { ...r, estimatedTime: r.advertisedTime! + 15 * 60_000, trackAtLocation: "5" } : r,
    );
    await run(now + 60 * 60_000);
    const stamps = push.sent.slice(1).map((p) => (p.payload as { aps: { timestamp: number } }).aps.timestamp);
    expect(stamps[1]).toBe(stamps[0]! + 1);
  });

  it("does not remove an activity re-registered with a new token during the tick", async () => {
    await follow(store, "a1");
    let release!: () => void;
    push.send = async () => {
      await new Promise<void>((r) => (release = r));
      return { status: 410, reason: "Unregistered" };
    };
    const pending = run(now);
    await new Promise((r) => setTimeout(r, 0));
    await follow(store, "a1", { token: "cd".repeat(32) });
    release();
    await pending;
    expect(store.registrations.get("a1")?.token).toBe("cd".repeat(32));
  });

  it("does not bring back the state of an activity deleted during the tick", async () => {
    await follow(store, "a1");
    let release!: () => void;
    const pending = tick({
      store,
      push,
      now,
      names: async () => new StationNames(),
      fetchJourneys: (keys) => new Promise((resolve) => (release = () => resolve(new Map(keys.map((k) => [k.id, rows]))))),
    });
    await new Promise((r) => setTimeout(r, 0));
    await store.remove([{ id: "a1", trainId: "837@2026-09-05" }]);
    release();
    await pending;
    expect(store.states.has("a1")).toBe(false);
  });

  it("keeps going when one run throws", async () => {
    await follow(store, "a1");
    await follow(store, "b1", { trainId: "838@2026-09-05", token: "cd".repeat(32) });
    push.send = async (p) => {
      if (p.token === token) {
        throw new Error("boom");
      }
      return { status: 200 };
    };
    const stats = await run(now);
    expect(stats.error).toBe("boom");
    expect(store.nextPoll.get("837@2026-09-05")).toBe(now + 120_000);
    // The other run was pushed and rescheduled as usual.
    expect(stats.pushed).toBe(1);
    expect(store.nextPoll.get("838@2026-09-05")).toBe(now + 60_000);
  });

  it("serves every activity on a run from one fetch, each with its own segment", async () => {
    await follow(store, "a1");
    await follow(store, "a2", { segment: { boarding: "Gä" } });
    let fetches = 0;
    await tick({
      store,
      push,
      now,
      names: async () => new StationNames(),
      fetchJourneys: async (keys) => {
        fetches += 1;
        return new Map(keys.map((k) => [k.id, rows]));
      },
    });
    expect(fetches).toBe(1);
    const statuses = push.sent.map((p) => (p.payload as { aps: { "content-state": { status: string } } }).aps["content-state"].status);
    expect(statuses.sort()).toEqual(["enRoute", "scheduled"]);
  });
});

describe("registration", () => {
  it("rejects what the app would never send", () => {
    const base = { activityId: "a1", token, trainId: "837@2026-09-05", bundleId: "se.tagradar.app", environment: "production" };
    const check = (patch: Record<string, unknown>) => validate({ ...base, ...patch }, ["se.tagradar.app"], now);
    expect(check({}).ok).toBe(true);
    expect(check({ token: "xyz" })).toEqual({ ok: false, error: "token" });
    expect(check({ trainId: "837@2026-10-05" })).toEqual({ ok: false, error: "trainId" });
    expect(check({ trainId: "<script>@2026-09-05" })).toEqual({ ok: false, error: "trainId" });
    expect(check({ bundleId: "com.example" })).toEqual({ ok: false, error: "bundleId" });
    expect(check({ environment: "staging" })).toEqual({ ok: false, error: "environment" });
    expect(check({ segment: { boarding: "Gä", alighting: "<x>" } })).toEqual({ ok: false, error: "segment" });
    expect(check({ segment: { boarding: "Gä" } })).toMatchObject({ ok: true, value: { segment: { boarding: "Gä" } } });
  });

  it("keeps alert state across token updates but not segment changes, and caps registrations", async () => {
    const store = new MemoryStore();
    await follow(store, "a1");
    store.states.set("a1", { segmentKey: "null", alertState: { canceled: false, arrived: false, boarded: false, delayMinutes: 7 } });
    await follow(store, "a1", { token: "cd".repeat(32) });
    expect(store.states.get("a1")?.alertState?.delayMinutes).toBe(7);
    await follow(store, "a1", { segment: { boarding: "U" } });
    expect(store.states.get("a1")).toBeUndefined();

    const v = validate({ activityId: "a2", token, trainId: "837@2026-09-05", bundleId: "x", environment: "production" }, ["x"], now);
    if (!v.ok) throw new Error(v.error);
    expect(await register(store, v.value, v.runStart, now, 1)).toEqual({ status: 503, error: "capacity" });
  });
});

describe("client address", () => {
  const address = (headers: Record<string, string>) => clientAddress(new Request("https://x/", { headers }));

  it("uses Vercel's headers and groups IPv6 by /64", () => {
    expect(address({ "x-real-ip": "62.20.1.2" })).toBe("62.20.1.2");
    expect(address({ "x-forwarded-for": "62.20.1.2, 10.0.0.1" })).toBe("62.20.1.2");
    expect(address({ "x-real-ip": "2a02:aa1:1003:0abc:1:2:3:4" })).toBe("2a02:aa1:1003:abc::/64");
    expect(address({ "x-real-ip": "2a02:aa1::5" })).toBe("2a02:aa1:0:0::/64");
    expect(address({})).toBe("unknown");
  });
});

describe("back-off with company", () => {
  it("does not retry a failing activity every minute just because the run is shared", async () => {
    const store = new MemoryStore();
    const sent: string[] = [];
    const push: PushSender = {
      async send(p) {
        sent.push(p.token);
        return p.token === token ? { status: 500, reason: "InternalServerError" } : { status: 200 };
      },
      close() {},
    };
    const rows = rowsOf("en-route-whole-run");
    await follow(store, "bad");
    await follow(store, "good", { token: "cd".repeat(32) });
    for (let i = 0; i < 4; i++) {
      await tick({ store, push, now: now + i * 60_000, names: async () => new StationNames(), fetchJourneys: async (keys) => new Map(keys.map((k) => [k.id, rows])) });
    }
    // Ticks at 0, 1, 2 and 3 minutes: the failing one is tried at 0, then after 1 and 2 more minutes.
    expect(sent.filter((t) => t === token)).toHaveLength(3);
  });
});

describe("dismissal", () => {
  const at = Date.parse("2026-09-05T11:00:00Z");

  it("clears a finished trip five minutes after it arrived, a cancellation after a quarter of an hour", () => {
    expect(dismissal("arrived", at - 60_000, at)).toBe(at + 4 * 60_000);
    expect(dismissal("arrived", at - 20 * 60_000, at)).toBe(at);
    expect(dismissal("enRoute", undefined, at)).toBe(at + 5 * 60_000);
    expect(dismissal("canceled", at, at)).toBe(at + 15 * 60_000);
  });
});
