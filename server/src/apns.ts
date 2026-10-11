import { createPrivateKey, sign, type KeyObject } from "node:crypto";
import { connect, type ClientHttp2Session } from "node:http2";

// A minimal APNs client for Live Activity pushes: token-based auth (ES256 JWT from a .p8 key) over
// HTTP/2. One key per Apple team; each key lists the bundle IDs it may push to.

export type ApnsEnvironment = "development" | "production";

export interface ApnsKeyConfig {
  teamId: string;
  keyId: string;
  /** PEM contents of the .p8 file. */
  privateKey: string;
  bundleIds: string[];
}

export interface LiveActivityPush {
  token: string;
  bundleId: string;
  environment: ApnsEnvironment;
  /** 10 shows immediately and counts against the update budget; 5 is delivered opportunistically. */
  priority: 5 | 10;
  payload: unknown;
}

export interface PushResult {
  status: number;
  reason?: string;
}

export interface PushSender {
  send(push: LiveActivityPush): Promise<PushResult>;
  close(): void;
}

const hosts: Record<ApnsEnvironment, string> = {
  development: "https://api.sandbox.push.apple.com",
  production: "https://api.push.apple.com",
};

/** Reads `APNS_KEYS`: a JSON array of `ApnsKeyConfig`. */
export function parseApnsKeys(raw: string | undefined): ApnsKeyConfig[] {
  if (!raw) {
    return [];
  }
  const parsed = JSON.parse(raw) as unknown;
  if (!Array.isArray(parsed)) {
    throw new Error("APNS_KEYS must be a JSON array");
  }
  return parsed.map((entry, i) => {
    const e = entry as Partial<ApnsKeyConfig>;
    if (!e.teamId || !e.keyId || !e.privateKey || !Array.isArray(e.bundleIds) || e.bundleIds.length === 0) {
      throw new Error(`APNS_KEYS[${i}] needs teamId, keyId, privateKey and bundleIds`);
    }
    return { teamId: e.teamId, keyId: e.keyId, privateKey: e.privateKey.replace(/\\n/g, "\n"), bundleIds: e.bundleIds };
  });
}

const base64url = (data: Buffer | string) => Buffer.from(data).toString("base64url");

interface CachedToken {
  jwt: string;
  issuedAt: number;
}

/**
 * Provider tokens are valid for an hour, and APNs refuses new ones more often than every 20 minutes.
 * `iat` is rounded down to a 20-minute window, so every function instance in the same window
 * presents the same issue time instead of each minting its own.
 */
const tokenWindow = 20 * 60_000;
const tokens = new Map<string, CachedToken>();
/** Keys whose last token APNs refused; the next one is issued now rather than at the window start. */
const refused = new Set<string>();
const keyObjects = new Map<string, KeyObject>();

export function providerToken(key: ApnsKeyConfig, now = Date.now()): string {
  const cached = tokens.get(key.keyId);
  if (cached && now - cached.issuedAt < tokenWindow) {
    return cached.jwt;
  }
  const issuedAt = refused.delete(key.keyId) ? now : Math.floor(now / tokenWindow) * tokenWindow;
  let keyObject = keyObjects.get(key.keyId);
  if (!keyObject) {
    keyObject = createPrivateKey(key.privateKey);
    keyObjects.set(key.keyId, keyObject);
  }
  const header = base64url(JSON.stringify({ alg: "ES256", kid: key.keyId }));
  const claims = base64url(JSON.stringify({ iss: key.teamId, iat: Math.floor(issuedAt / 1000) }));
  const signature = sign("sha256", Buffer.from(`${header}.${claims}`), { key: keyObject, dsaEncoding: "ieee-p1363" });
  const jwt = `${header}.${claims}.${base64url(signature)}`;
  tokens.set(key.keyId, { jwt, issuedAt });
  return jwt;
}

/** Forgets a provider token APNs refused, so the next push signs a new one. A late answer about a token
 * that was already replaced (parallel pushes) leaves the new one alone. */
export function discardProviderToken(keyId: string, jwt: string): void {
  if (tokens.get(keyId)?.jwt !== jwt) {
    return;
  }
  tokens.delete(keyId);
  refused.add(keyId);
}

export class ApnsClient implements PushSender {
  private readonly sessions = new Map<ApnsEnvironment, ClientHttp2Session>();

  constructor(private readonly keys: ApnsKeyConfig[]) {}

  get bundleIds(): string[] {
    return this.keys.flatMap((k) => k.bundleIds);
  }

  private session(environment: ApnsEnvironment): ClientHttp2Session {
    let session = this.sessions.get(environment);
    if (!session || session.closed || session.destroyed) {
      session = connect(hosts[environment]);
      session.on("error", () => this.sessions.delete(environment));
      this.sessions.set(environment, session);
    }
    return session;
  }

  send(push: LiveActivityPush): Promise<PushResult> {
    const key = this.keys.find((k) => k.bundleIds.includes(push.bundleId));
    if (!key) {
      return Promise.resolve({ status: 0, reason: "NoKeyForBundleId" });
    }
    const body = JSON.stringify(push.payload);
    return new Promise((resolve) => {
      const jwt = providerToken(key);
      const request = this.session(push.environment).request({
        ":method": "POST",
        ":path": `/3/device/${push.token}`,
        authorization: `bearer ${jwt}`,
        "apns-push-type": "liveactivity",
        "apns-topic": `${push.bundleId}.push-type.liveactivity`,
        "apns-priority": String(push.priority),
        "content-type": "application/json",
        "content-length": Buffer.byteLength(body),
      });
      let status = 0;
      let data = "";
      request.setEncoding("utf8");
      request.setTimeout(10_000, () => request.close());
      request.on("response", (headers) => {
        status = Number(headers[":status"] ?? 0);
      });
      request.on("data", (chunk: string) => {
        data += chunk;
      });
      request.on("end", () => {
        let reason: string | undefined;
        try {
          reason = data ? (JSON.parse(data) as { reason?: string }).reason : undefined;
        } catch {
          reason = undefined;
        }
        if (status === 403 && (reason === "ExpiredProviderToken" || reason === "InvalidProviderToken")) {
          discardProviderToken(key.keyId, jwt);
        }
        resolve({ status, reason });
      });
      request.on("error", (error) => resolve({ status: 0, reason: error.message }));
      // After a timeout or reset no "end" arrives; whichever settles first wins.
      request.on("close", () => resolve({ status, reason: status ? undefined : "Closed" }));
      request.end(body);
    });
  }

  close(): void {
    for (const session of this.sessions.values()) {
      session.close();
    }
    this.sessions.clear();
  }
}
