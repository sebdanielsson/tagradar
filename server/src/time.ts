// Time helpers. Instants are epoch milliseconds throughout; Swift `Date`s only appear at the edge,
// in the content state ActivityKit decodes (see `contentState.ts`).

const zone = "Europe/Stockholm";

const partsFormat = new Intl.DateTimeFormat("en-US", {
  timeZone: zone,
  hourCycle: "h23",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
});

const clockFormat = new Intl.DateTimeFormat("sv-SE", {
  timeZone: zone,
  hourCycle: "h23",
  hour: "2-digit",
  minute: "2-digit",
});

/** Seconds between 1970-01-01 and 2001-01-01, Foundation's reference date. */
export const referenceDateOffset = 978_307_200;

/** A Swift `Date` as `JSONDecoder`'s default strategy reads it: seconds since 2001-01-01. */
export function swiftDate(ms: number): number {
  return ms / 1000 - referenceDateOffset;
}

function stockholmFields(ms: number): Record<string, number> {
  const fields: Record<string, number> = {};
  for (const part of partsFormat.formatToParts(new Date(ms))) {
    if (part.type !== "literal") {
      fields[part.type] = Number(part.value);
    }
  }
  return fields;
}

/** How far Stockholm civil time is ahead of UTC at an instant. */
function stockholmOffset(ms: number): number {
  const f = stockholmFields(ms);
  const asUTC = Date.UTC(f.year!, f.month! - 1, f.day!, f.hour!, f.minute!, f.second!);
  return asUTC - Math.floor(ms / 1000) * 1000;
}

/** The instant a Stockholm wall-clock time refers to. */
export function stockholmInstant(year: number, month: number, day: number, hour = 0, minute = 0, second = 0, ms = 0): number {
  const wall = Date.UTC(year, month - 1, day, hour, minute, second, ms);
  const guess = wall - stockholmOffset(wall);
  return wall - stockholmOffset(guess);
}

/**
 * Parses the timestamp shapes Trafikverket emits, like `TRVDateParser`: with an offset, in UTC, or
 * without a zone (Stockholm civil time).
 */
export function parseTrvDate(value: string | undefined | null): number | undefined {
  if (!value) {
    return undefined;
  }
  if (/(?:[zZ]|[+-]\d{2}:\d{2})$/.test(value)) {
    const ms = Date.parse(value);
    return Number.isNaN(ms) ? undefined : ms;
  }
  const m = /^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?)?$/.exec(value);
  if (!m) {
    return undefined;
  }
  const n = (i: number) => Number(m[i] ?? 0);
  return stockholmInstant(n(1), n(2), n(3), n(4), n(5), n(6), Number((m[7] ?? "0").padEnd(3, "0")));
}

/** `yyyy-MM-dd` in Stockholm. */
export function stockholmDay(ms: number): string {
  const f = stockholmFields(ms);
  return `${f.year}-${String(f.month).padStart(2, "0")}-${String(f.day).padStart(2, "0")}`;
}

/** Start of a `yyyy-MM-dd` day in Stockholm, or undefined when the string is not a real date. */
export function dayStart(day: string): number | undefined {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(day);
  if (!m) {
    return undefined;
  }
  const [year, month, date] = [Number(m[1]), Number(m[2]), Number(m[3])];
  const check = new Date(Date.UTC(year, month - 1, date));
  if (check.getUTCMonth() !== month - 1 || check.getUTCDate() !== date) {
    return undefined;
  }
  return stockholmInstant(year, month, date);
}

/** `HH:mm` in Stockholm, like `Format.clock`. */
export function clock(ms: number | undefined): string {
  return ms === undefined ? "–" : clockFormat.format(new Date(ms));
}
