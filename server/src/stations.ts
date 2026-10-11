import { StationNames } from "./contentState.js";
import { fetchStations } from "./trafikverket.js";

// Station names change rarely; each function instance loads them once a day and keeps them in memory.

const refreshAfter = 24 * 60 * 60_000;
const retryAfter = 60 * 60_000;

let cached: { names: StationNames; loadedAt: number } | undefined;

export async function stationNames(apiKey: string, now = Date.now()): Promise<StationNames> {
  if (cached && now - cached.loadedAt < refreshAfter) {
    return cached.names;
  }
  try {
    const stations = await fetchStations(apiKey);
    if (stations.size > 0) {
      cached = { names: new StationNames(stations), loadedAt: now };
    }
  } catch (error) {
    console.error(JSON.stringify({ msg: "station list failed", error: error instanceof Error ? error.message : String(error) }));
    if (cached) {
      // Keep the old list and try again in an hour.
      cached.loadedAt = now - refreshAfter + retryAfter;
    }
  }
  // Without a list, signatures stand in for names, like `StationNames.empty` in the app.
  return cached?.names ?? new StationNames();
}
