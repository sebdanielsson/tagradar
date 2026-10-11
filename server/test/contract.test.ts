import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { contentState, encode, StationNames } from "../src/contentState.js";
import { buildJourney } from "../src/journey.js";
import { snapshot, type Segment } from "../src/snapshot.js";
import { parseAnnouncements, parseTrainKey, type Station } from "../src/trafikverket.js";

const directory = join(import.meta.dirname, "fixtures", "contract");

interface Fixture {
  description: string;
  trainId: string;
  segment: Segment | null;
  now: string;
  stations: { LocationSignature: string; AdvertisedLocationName?: string; AdvertisedShortLocationName?: string }[];
  response: { RESPONSE: { RESULT: Record<string, unknown>[] } };
  expected?: Record<string, unknown>;
}

function render(fixture: Fixture): Record<string, unknown> {
  const key = parseTrainKey(fixture.trainId)!;
  const stations = new Map<string, Station>(
    fixture.stations.map((s) => [
      s.LocationSignature,
      { name: s.AdvertisedLocationName ?? s.AdvertisedShortLocationName ?? s.LocationSignature, shortName: s.AdvertisedShortLocationName },
    ]),
  );
  const journey = buildJourney(parseAnnouncements(fixture.response.RESPONSE.RESULT[0]));
  const snap = snapshot(key.ident, journey, fixture.segment);
  return encode(contentState(snap, new StationNames(stations), Date.parse(fixture.now)));
}

describe("content state contract", () => {
  for (const file of readdirSync(directory).filter((f) => f.endsWith(".json"))) {
    it(file, () => {
      const path = join(directory, file);
      const fixture = JSON.parse(readFileSync(path, "utf8")) as Fixture;
      const actual = render(fixture);
      if (process.env.UPDATE_CONTRACT) {
        writeFileSync(path, `${JSON.stringify({ ...fixture, expected: actual }, null, 2)}\n`);
        return;
      }
      expect(actual).toEqual(fixture.expected);
    });
  }
});
