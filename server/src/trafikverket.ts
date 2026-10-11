import { parseTrvDate } from "./time.js";

// The slice of Trafikverket's Open API the push server needs: train announcements for a set of runs
// and the station list. Mirrors `TrafikverketKit`, see docs/trafikverket-api.md.

const endpoint = "https://api.trafikinfo.trafikverket.se/v2/data.json";
const userAgent = "Tagradar push (+https://github.com/sebdanielsson/tagradar)";

/** One arrival or departure row, reduced to what `TrainSnapshot` reads. Times are epoch ms. */
export interface Announcement {
  activityType?: "arrival" | "departure";
  advertised?: boolean;
  advertisedTime?: number;
  estimatedTime?: number;
  /** `TimeAtLocation`: set once the train has actually arrived or left. */
  actualTime?: number;
  canceled: boolean;
  locationSignature?: string;
  modifiedTime?: number;
  operator?: string;
  products: string[];
  trackAtLocation?: string;
}

/** A run as the app identifies it: `TrainKey.id`, `<ident>@<yyyy-MM-dd>`. */
export interface TrainKey {
  id: string;
  ident: string;
  day: string;
}

export function parseTrainKey(id: string): TrainKey | undefined {
  const m = /^([0-9A-Za-z]{1,10})@(\d{4}-\d{2}-\d{2})$/.exec(id);
  return m ? { id, ident: m[1]!, day: m[2]! } : undefined;
}

const announcementFields = [
  "ActivityType",
  "Advertised",
  "AdvertisedTimeAtLocation",
  "Canceled",
  "Deleted",
  "EstimatedTimeAtLocation",
  "LocationSignature",
  "ModifiedTime",
  "Operator",
  "ProductInformation",
  "TimeAtLocation",
  "TrackAtLocation",
];

const stationFields = ["AdvertisedLocationName", "AdvertisedShortLocationName", "LocationSignature", "OfficialLocationName"];

function xml(value: string): string {
  return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&apos;");
}

function includes(fields: string[]): string {
  return fields.map((f) => `    <INCLUDE>${f}</INCLUDE>\n`).join("");
}

/** Same filter as `TrainService.announcementsQuery`, one `<QUERY>` per run. */
function announcementsQuery(key: TrainKey): string {
  return (
    `  <QUERY objecttype="TrainAnnouncement" namespace="rail.trafficinfo" schemaversion="2.0" limit="1000" orderby="AdvertisedTimeAtLocation asc">\n` +
    `    <FILTER>\n      <AND>\n` +
    `        <EQ name="AdvertisedTrainIdent" value="${xml(key.ident)}" />\n` +
    `        <GTE name="ScheduledDepartureDateTime" value="${xml(key.day)}T00:00:00" />\n` +
    `        <LT name="ScheduledDepartureDateTime" value="${xml(key.day)}T23:59:59" />\n` +
    `      </AND>\n    </FILTER>\n` +
    includes(announcementFields) +
    `  </QUERY>\n`
  );
}

function request(apiKey: string, queries: string[]): string {
  return `<REQUEST>\n  <LOGIN authenticationkey="${xml(apiKey)}" />\n${queries.join("")}</REQUEST>\n`;
}

type Raw = Record<string, unknown>;

async function post(body: string, fetchImpl: typeof fetch): Promise<Raw[]> {
  const response = await fetchImpl(endpoint, {
    method: "POST",
    headers: { "Content-Type": "text/xml; charset=utf-8", Accept: "application/json", "User-Agent": userAgent },
    body,
    signal: AbortSignal.timeout(20_000),
  });
  const json = (await response.json().catch(() => undefined)) as { RESPONSE?: { RESULT?: Raw[] } } | undefined;
  const results = json?.RESPONSE?.RESULT;
  const error = results?.find((r) => r.ERROR)?.ERROR as { MESSAGE?: string } | undefined;
  if (!response.ok || !results || error) {
    throw new Error(`Trafikverket: ${error?.MESSAGE ?? `HTTP ${response.status}`}`);
  }
  return results;
}

function descriptions(value: unknown): string[] {
  if (!Array.isArray(value)) {
    return [];
  }
  return value.flatMap((item) => {
    const description = (item as Raw | null)?.Description;
    return typeof description === "string" ? [description] : [];
  });
}

const str = (v: unknown) => (typeof v === "string" ? v : undefined);
const bool = (v: unknown) => (typeof v === "boolean" ? v : undefined);

export function parseAnnouncement(raw: Raw): Announcement {
  const type = raw.ActivityType;
  return {
    activityType: type === "Ankomst" ? "arrival" : type === "Avgang" ? "departure" : undefined,
    advertised: bool(raw.Advertised),
    advertisedTime: parseTrvDate(str(raw.AdvertisedTimeAtLocation)),
    estimatedTime: parseTrvDate(str(raw.EstimatedTimeAtLocation)),
    actualTime: parseTrvDate(str(raw.TimeAtLocation)),
    canceled: raw.Canceled === true,
    locationSignature: str(raw.LocationSignature),
    modifiedTime: parseTrvDate(str(raw.ModifiedTime)),
    operator: str(raw.Operator),
    products: descriptions(raw.ProductInformation),
    trackAtLocation: str(raw.TrackAtLocation),
  };
}

/** Rows of one result block, without deleted ones, in the order the API returned them. */
export function parseAnnouncements(block: Raw | undefined): Announcement[] {
  const rows = block?.TrainAnnouncement;
  if (!Array.isArray(rows)) {
    return [];
  }
  return (rows as Raw[]).filter((r) => r.Deleted !== true).map(parseAnnouncement);
}

export type JourneyFetcher = (keys: TrainKey[]) => Promise<Map<string, Announcement[]>>;

/** Loads every listed run in one round trip. */
export function journeyFetcher(apiKey: string, fetchImpl: typeof fetch = fetch): JourneyFetcher {
  return async (keys) => {
    const result = new Map<string, Announcement[]>();
    if (keys.length === 0) {
      return result;
    }
    const blocks = await post(request(apiKey, keys.map(announcementsQuery)), fetchImpl);
    keys.forEach((key, i) => result.set(key.id, parseAnnouncements(blocks[i])));
    return result;
  };
}

export interface Station {
  name: string;
  shortName?: string;
}

/** Every advertised station, keyed by signature, as `StationDirectory` loads them. */
export async function fetchStations(apiKey: string, fetchImpl: typeof fetch = fetch): Promise<Map<string, Station>> {
  const query =
    `  <QUERY objecttype="TrainStation" namespace="rail.infrastructure" schemaversion="1.5" limit="5000">\n` +
    `    <FILTER>\n      <EQ name="Advertised" value="true" />\n    </FILTER>\n` +
    includes(stationFields) +
    `  </QUERY>\n`;
  const [block] = await post(request(apiKey, [query]), fetchImpl);
  const stations = new Map<string, Station>();
  for (const raw of (block?.TrainStation as Raw[] | undefined) ?? []) {
    const signature = str(raw.LocationSignature);
    if (!signature || raw.Deleted === true || stations.has(signature)) {
      continue;
    }
    const short = str(raw.AdvertisedShortLocationName);
    stations.set(signature, {
      name: str(raw.AdvertisedLocationName) ?? str(raw.OfficialLocationName) ?? short ?? signature,
      shortName: short,
    });
  }
  return stations;
}
