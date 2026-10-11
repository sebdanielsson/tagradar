import { authorized, clientAddress, json, loadConfig, serverError } from "../src/config.js";
import { register, validate } from "../src/registration.js";
import { RedisStore } from "../src/store.js";

/** Registers or updates a followed train's Live Activity. */
export async function POST(request: Request): Promise<Response> {
  try {
    const config = loadConfig();
    if (!authorized(request, config.appSecret)) {
      return json(401, { error: "unauthorized" });
    }
    const now = Date.now();
    const store = RedisStore.fromEnv();
    // The app only registers when something changed, so this is far above what a phone sends; it
    // keeps someone holding the (extractable) app secret from burning through the free tier.
    if (!(await store.allow(clientAddress(request), config.registrationsPerHour, now))) {
      return json(429, { error: "rate limited" });
    }
    const body = (await request.json().catch(() => undefined)) as unknown;
    const validated = validate(
      body,
      config.apnsKeys.flatMap((k) => k.bundleIds),
      now,
    );
    if (!validated.ok) {
      return json(400, { error: validated.error });
    }
    const result = await register(store, validated.value, validated.runStart, now, config.maxActivities);
    return result.error ? json(result.status, { error: result.error }) : new Response(null, { status: result.status });
  } catch (error) {
    return serverError(error);
  }
}
