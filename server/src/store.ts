import { Redis } from "@upstash/redis";
import type { AlertKind, AlertState } from "./alerts.js";
import type { ApnsEnvironment } from "./apns.js";
import type { Segment } from "./snapshot.js";

// Everything the server remembers, in Upstash Redis (free plan: 500k commands a month, so every
// method costs as few commands as it can). Keys expire on their own a few days after the run.
//
//   activity:<id>   JSON Registration, written only by the app's requests
//   state:<id>      JSON ActivityState, written only by the tick, so neither overwrites the other
//   train:<trainId> set of activity IDs following that run
//   trains          sorted set of run IDs, scored by when to poll them next (epoch ms)
//   activities      sorted set of every activity ID, scored by when its record expires (the cap)
//   limit:<ip>:<h>  registrations from one address in one hour

/** What the app registered for one Live Activity. */
export interface Registration {
  /** `Activity.id` on the phone. */
  id: string;
  trainId: string;
  /** Hex push token of the activity. */
  token: string;
  bundleId: string;
  environment: ApnsEnvironment;
  segment: Segment | null;
  /** Whether the user wants delay, track and arrival alerts for this train. */
  alerts: boolean;
  createdAt: number;
}

/** What the tick has worked out and told an activity so far. */
export interface ActivityState {
  /** The segment this state was built for; a different one means starting over. */
  segmentKey: string;
  alertState?: AlertState;
  /** Hash of the last content state pushed, to skip unchanged ones. */
  lastHash?: string;
  /** Stale date (epoch ms) of the last push; refreshed before it passes even when nothing changed. */
  lastStaleAt?: number;
  lastStatus?: string;
  lastNextStop?: string;
  /** Set when APNs said the token belongs to the other environment than the app reported. */
  environment?: ApnsEnvironment;
  /** Consecutive failed pushes, for backing off. */
  failures?: number;
  /** No push before this (epoch ms) while backing off; the run may still be polled for others. */
  retryAt?: number;
  /** Alerts evaluated but not yet delivered, because a push failed after an earlier one went through. */
  pendingAlerts?: AlertKind[];
}

export interface Activity {
  registration: Registration;
  state?: ActivityState;
}

export interface Claim {
  trainId: string;
  /** The score the claim set; settling only moves runs nobody touched since. */
  lease: number;
}

export interface Settlement extends Claim {
  /** When to poll the run next; null when its activities are all gone. */
  next: number | null;
}

export interface Store {
  get(id: string): Promise<Registration | null>;
  /** Adds or replaces a registration and polls its run at the next tick. */
  register(registration: Registration, options: { ttlSeconds: number; now: number; resetState: boolean }): Promise<void>;
  remove(activities: Pick<Registration, "id" | "trainId">[]): Promise<void>;
  /** Like `remove`, but leaves an activity alone if it was re-registered with another token meanwhile. */
  removeIfToken(activities: Pick<Registration, "id" | "trainId" | "token">[]): Promise<void>;
  /** Registrations that have not expired. */
  count(now: number): Promise<number>;
  /** Counts a request from `client` and says whether it is within `limit` this hour. */
  allow(client: string, limit: number, now: number): Promise<boolean>;
  /** Takes the runs that are due, oldest first, and leases them until `leaseUntil` so overlapping ticks skip them. */
  claimDue(now: number, limit: number, leaseUntil: number): Promise<Claim[]>;
  activitiesFor(trainIds: string[]): Promise<Map<string, Activity[]>>;
  /** Writes tick state for activities that are still registered, expiring with their registration. */
  saveStates(states: { id: string; state: ActivityState }[]): Promise<void>;
  /** Reschedules claimed runs, unless a registration moved them meanwhile; drops runs nobody follows. */
  settle(settlements: Settlement[], now: number): Promise<void>;
}


const claimScript = `
local due = redis.call('ZRANGEBYSCORE', KEYS[1], '-inf', ARGV[1], 'LIMIT', 0, tonumber(ARGV[2]))
for _, member in ipairs(due) do
  redis.call('ZADD', KEYS[1], 'XX', ARGV[3], member)
end
return due
`;

// KEYS[1] = trains, KEYS[1 + i] = train:<id> of the i-th settlement; ARGV = now, then member, lease, next per settlement.
const settleScript = `
for i = 2, #KEYS do
  local base = 2 + (i - 2) * 3
  local member, lease, nextPoll = ARGV[base], ARGV[base + 1], ARGV[base + 2]
  local score = redis.call('ZSCORE', KEYS[1], member)
  if score and tonumber(score) == tonumber(lease) then
    if nextPoll ~= '-' then
      redis.call('ZADD', KEYS[1], nextPoll, member)
    elseif redis.call('SCARD', KEYS[i]) == 0 then
      redis.call('ZREM', KEYS[1], member)
    else
      redis.call('ZADD', KEYS[1], ARGV[1], member)
    end
  end
end
return 1
`;

// KEYS = activity:<id>, state:<id> per state; ARGV = the states' JSON.
const saveStatesScript = `
for i = 1, #ARGV do
  local ttl = redis.call('PTTL', KEYS[2 * i - 1])
  if ttl > 0 then
    redis.call('SET', KEYS[2 * i], ARGV[i], 'PX', ttl)
  end
end
return 1
`;

// KEYS[1] = activities, then activity:<id>, state:<id>, train:<trainId> per activity; ARGV = id, token per activity.
const removeIfTokenScript = `
for i = 1, #ARGV / 2 do
  local base = 2 + (i - 1) * 3
  local id, token = ARGV[2 * i - 1], ARGV[2 * i]
  local raw = redis.call('GET', KEYS[base])
  if not raw or string.find(raw, '"token":"' .. token .. '"', 1, true) then
    redis.call('DEL', KEYS[base], KEYS[base + 1])
    redis.call('ZREM', KEYS[1], id)
    redis.call('SREM', KEYS[base + 2], id)
  end
end
return 1
`;

export class RedisStore implements Store {
  constructor(
    private readonly redis: Redis,
    private readonly prefix = "tagradar:",
  ) {}

  /** Reads Upstash's own variables, or the ones the Vercel Marketplace integration sets (`KV_REST_API_*`). */
  static fromEnv(env: NodeJS.ProcessEnv = process.env): RedisStore {
    const url = env.UPSTASH_REDIS_REST_URL ?? env.KV_REST_API_URL;
    const token = env.UPSTASH_REDIS_REST_TOKEN ?? env.KV_REST_API_TOKEN;
    if (!url || !token) {
      throw new Error("Upstash Redis is not configured (UPSTASH_REDIS_REST_URL / UPSTASH_REDIS_REST_TOKEN)");
    }
    return new RedisStore(new Redis({ url, token, automaticDeserialization: false }));
  }

  private activityKey = (id: string) => `${this.prefix}activity:${id}`;
  private stateKey = (id: string) => `${this.prefix}state:${id}`;
  private trainKey = (trainId: string) => `${this.prefix}train:${trainId}`;
  private get trainsKey() {
    return `${this.prefix}trains`;
  }
  private get allKey() {
    return `${this.prefix}activities`;
  }

  async get(id: string): Promise<Registration | null> {
    const raw = await this.redis.get<string>(this.activityKey(id));
    return raw ? (JSON.parse(raw) as Registration) : null;
  }

  async register(registration: Registration, { ttlSeconds, now, resetState }: { ttlSeconds: number; now: number; resetState: boolean }) {
    const p = this.redis.pipeline();
    p.set(this.activityKey(registration.id), JSON.stringify(registration), { ex: ttlSeconds });
    if (resetState) {
      p.del(this.stateKey(registration.id));
    }
    p.sadd(this.trainKey(registration.trainId), registration.id);
    p.expire(this.trainKey(registration.trainId), ttlSeconds);
    p.zadd(this.allKey, { score: now + ttlSeconds * 1000, member: registration.id });
    p.zremrangebyscore(this.allKey, "-inf", now);
    p.zadd(this.trainsKey, { score: now, member: registration.trainId });
    await p.exec();
  }

  async remove(activities: Pick<Registration, "id" | "trainId">[]): Promise<void> {
    if (activities.length === 0) {
      return;
    }
    const p = this.redis.pipeline();
    p.del(...activities.flatMap((a) => [this.activityKey(a.id), this.stateKey(a.id)]));
    p.zrem(this.allKey, ...activities.map((a) => a.id));
    for (const a of activities) {
      p.srem(this.trainKey(a.trainId), a.id);
    }
    await p.exec();
  }

  async removeIfToken(activities: Pick<Registration, "id" | "trainId" | "token">[]): Promise<void> {
    if (activities.length === 0) {
      return;
    }
    await this.redis.eval(
      removeIfTokenScript,
      [this.allKey, ...activities.flatMap((a) => [this.activityKey(a.id), this.stateKey(a.id), this.trainKey(a.trainId)])],
      activities.flatMap((a) => [a.id, a.token]),
    );
  }

  count(now: number): Promise<number> {
    return this.redis.zcount(this.allKey, now, "+inf");
  }

  async allow(client: string, limit: number, now: number): Promise<boolean> {
    const key = `${this.prefix}limit:${client}:${Math.floor(now / 3_600_000)}`;
    const p = this.redis.pipeline();
    p.incr(key);
    p.expire(key, 3600);
    const [count] = (await p.exec()) as [number, number];
    return count <= limit;
  }

  async claimDue(now: number, limit: number, leaseUntil: number): Promise<Claim[]> {
    const due = (await this.redis.eval(claimScript, [this.trainsKey], [String(now), String(limit), String(leaseUntil)])) as string[];
    return due.map((trainId) => ({ trainId, lease: leaseUntil }));
  }

  async activitiesFor(trainIds: string[]): Promise<Map<string, Activity[]>> {
    const result = new Map<string, Activity[]>(trainIds.map((id) => [id, []]));
    if (trainIds.length === 0) {
      return result;
    }
    const p = this.redis.pipeline();
    for (const trainId of trainIds) {
      p.smembers(this.trainKey(trainId));
    }
    const members = (await p.exec()) as string[][];
    const pairs = trainIds.flatMap((trainId, i) => (members[i] ?? []).map((id) => ({ trainId, id })));
    if (pairs.length === 0) {
      return result;
    }
    const raws = await this.redis.mget<(string | null)[]>(...pairs.flatMap((pair) => [this.activityKey(pair.id), this.stateKey(pair.id)]));
    const dangling: { id: string; trainId: string }[] = [];
    pairs.forEach((pair, i) => {
      const registration = raws[2 * i];
      const state = raws[2 * i + 1];
      if (registration) {
        result.get(pair.trainId)!.push({
          registration: JSON.parse(registration) as Registration,
          state: state ? (JSON.parse(state) as ActivityState) : undefined,
        });
      } else {
        dangling.push(pair);
      }
    });
    // Records that expired on their own leave their IDs behind in the sets.
    await this.remove(dangling);
    return result;
  }

  async saveStates(states: { id: string; state: ActivityState }[]): Promise<void> {
    if (states.length === 0) {
      return;
    }
    await this.redis.eval(
      saveStatesScript,
      states.flatMap(({ id }) => [this.activityKey(id), this.stateKey(id)]),
      states.map(({ state }) => JSON.stringify(state)),
    );
  }

  async settle(settlements: Settlement[], now: number): Promise<void> {
    if (settlements.length === 0) {
      return;
    }
    await this.redis.eval(
      settleScript,
      [this.trainsKey, ...settlements.map((s) => this.trainKey(s.trainId))],
      [String(now), ...settlements.flatMap((s) => [s.trainId, String(s.lease), s.next === null ? "-" : String(s.next)])],
    );
  }
}

/** In-memory store for tests, with the same claim and settle rules as the Redis scripts. Ignores TTLs. */
export class MemoryStore implements Store {
  readonly registrations = new Map<string, Registration>();
  readonly states = new Map<string, ActivityState>();
  readonly trains = new Map<string, Set<string>>();
  readonly nextPoll = new Map<string, number>();
  private readonly hits = new Map<string, number>();

  async get(id: string) {
    const registration = this.registrations.get(id);
    return registration ? structuredClone(registration) : null;
  }

  async register(registration: Registration, { now, resetState }: { ttlSeconds: number; now: number; resetState: boolean }) {
    this.registrations.set(registration.id, structuredClone(registration));
    if (resetState) {
      this.states.delete(registration.id);
    }
    const set = this.trains.get(registration.trainId) ?? new Set();
    set.add(registration.id);
    this.trains.set(registration.trainId, set);
    this.nextPoll.set(registration.trainId, now);
  }

  async remove(activities: Pick<Registration, "id" | "trainId">[]) {
    for (const a of activities) {
      this.registrations.delete(a.id);
      this.states.delete(a.id);
      this.trains.get(a.trainId)?.delete(a.id);
    }
  }

  async removeIfToken(activities: Pick<Registration, "id" | "trainId" | "token">[]) {
    await this.remove(activities.filter((a) => (this.registrations.get(a.id)?.token ?? a.token) === a.token));
  }

  async count() {
    return this.registrations.size;
  }

  async allow(client: string, limit: number, now: number) {
    const key = `${client}:${Math.floor(now / 3_600_000)}`;
    const count = (this.hits.get(key) ?? 0) + 1;
    this.hits.set(key, count);
    return count <= limit;
  }

  async claimDue(now: number, limit: number, leaseUntil: number) {
    const due = [...this.nextPoll.entries()]
      .filter(([, at]) => at <= now)
      .sort((a, b) => a[1] - b[1])
      .slice(0, limit)
      .map(([id]) => id);
    for (const id of due) {
      this.nextPoll.set(id, leaseUntil);
    }
    return due.map((trainId) => ({ trainId, lease: leaseUntil }));
  }

  async activitiesFor(trainIds: string[]) {
    return new Map(
      trainIds.map((trainId) => [
        trainId,
        [...(this.trains.get(trainId) ?? [])].flatMap((id) => {
          const registration = this.registrations.get(id);
          const state = this.states.get(id);
          return registration ? [{ registration: structuredClone(registration), state: state && structuredClone(state) }] : [];
        }),
      ]),
    );
  }

  async saveStates(states: { id: string; state: ActivityState }[]) {
    for (const { id, state } of states) {
      if (this.registrations.has(id)) {
        this.states.set(id, structuredClone(state));
      }
    }
  }

  async settle(settlements: Settlement[], now: number) {
    for (const s of settlements) {
      if (this.nextPoll.get(s.trainId) !== s.lease) {
        continue;
      }
      if (s.next !== null) {
        this.nextPoll.set(s.trainId, s.next);
      } else if ((this.trains.get(s.trainId)?.size ?? 0) === 0) {
        this.nextPoll.delete(s.trainId);
        this.trains.delete(s.trainId);
      } else {
        this.nextPoll.set(s.trainId, now);
      }
    }
  }
}
