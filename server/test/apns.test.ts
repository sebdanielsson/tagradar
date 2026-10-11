import { createPublicKey, generateKeyPairSync, verify } from "node:crypto";
import { describe, expect, it } from "vitest";
import { discardProviderToken, parseApnsKeys, providerToken } from "../src/apns.js";

describe("APNs", () => {
  const { privateKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const pem = privateKey.export({ type: "pkcs8", format: "pem" }).toString();

  it("reads keys with escaped newlines, as pasted into an env var", () => {
    const [key] = parseApnsKeys(JSON.stringify([{ teamId: "T", keyId: "K", privateKey: pem.replace(/\n/g, "\\n"), bundleIds: ["a"] }]));
    expect(key?.privateKey).toBe(pem);
    expect(() => parseApnsKeys('[{"teamId":"T"}]')).toThrow();
  });

  it("signs an ES256 provider token and reuses it within a 20-minute window", () => {
    const key = { teamId: "TEAM123456", keyId: "KEY1234567", privateKey: pem, bundleIds: ["se.tagradar.app"] };
    const now = Date.parse("2026-09-05T08:00:00Z");
    const jwt = providerToken(key, now);
    const [header, claims, signature] = jwt.split(".");
    expect(JSON.parse(Buffer.from(header!, "base64url").toString())).toEqual({ alg: "ES256", kid: "KEY1234567" });
    expect(JSON.parse(Buffer.from(claims!, "base64url").toString())).toEqual({ iss: "TEAM123456", iat: now / 1000 });
    const valid = verify(
      "sha256",
      Buffer.from(`${header}.${claims}`),
      { key: createPublicKey(privateKey), dsaEncoding: "ieee-p1363" },
      Buffer.from(signature!, "base64url"),
    );
    expect(valid).toBe(true);
    expect(providerToken(key, now + 19 * 60_000)).toBe(jwt);
    const next = providerToken(key, now + 21 * 60_000);
    expect(next).not.toBe(jwt);
    // A late refusal of the old token leaves the new one alone; refusing the current one replaces it.
    discardProviderToken(key.keyId, jwt);
    expect(providerToken(key, now + 22 * 60_000)).toBe(next);
    discardProviderToken(key.keyId, next);
    const fresh = providerToken(key, now + 22 * 60_000);
    expect(fresh).not.toBe(next);
    expect(JSON.parse(Buffer.from(fresh.split(".")[1]!, "base64url").toString()).iat).toBe((now + 22 * 60_000) / 1000);
  });
});
