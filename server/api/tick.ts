import { ApnsClient } from "../src/apns.js";
import { authorized, json, loadConfig, serverError } from "../src/config.js";
import { stationNames } from "../src/stations.js";
import { RedisStore } from "../src/store.js";
import { tick } from "../src/tick.js";
import { journeyFetcher } from "../src/trafikverket.js";

/** Called every minute by the external scheduler (Hobby's own cron only runs daily). */
async function handle(request: Request): Promise<Response> {
  let push: ApnsClient | undefined;
  try {
    const config = loadConfig();
    if (!authorized(request, config.cronSecret)) {
      return json(401, { error: "unauthorized" });
    }
    push = new ApnsClient(config.apnsKeys);
    const stats = await tick({
      store: RedisStore.fromEnv(),
      fetchJourneys: journeyFetcher(config.trafikverketApiKey),
      names: () => stationNames(config.trafikverketApiKey),
      push,
      now: Date.now(),
    });
    if (stats.due > 0) {
      console.log(JSON.stringify({ msg: "tick", ...stats }));
    }
    // Counts only: an error's text stays in the logs.
    const { error, ...counts } = stats;
    return json(200, { ...counts, error: error !== undefined });
  } catch (error) {
    return serverError(error);
  } finally {
    push?.close();
  }
}

export const GET = handle;
export const POST = handle;
