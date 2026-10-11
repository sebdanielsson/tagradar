import { describe, expect, it } from "vitest";
import { clock, dayStart, parseTrvDate, stockholmDay, swiftDate } from "../src/time.js";

describe("time", () => {
  it("parses every shape Trafikverket emits", () => {
    expect(parseTrvDate("2026-09-02T10:15:00.000+02:00")).toBe(Date.parse("2026-09-02T08:15:00Z"));
    expect(parseTrvDate("2026-09-02T08:15:00.123Z")).toBe(Date.parse("2026-09-02T08:15:00.123Z"));
    // Without a zone: Stockholm civil time, summer and winter.
    expect(parseTrvDate("2026-09-02T00:00:00")).toBe(Date.parse("2026-09-01T22:00:00Z"));
    expect(parseTrvDate("2026-01-15T12:00:00")).toBe(Date.parse("2026-01-15T11:00:00Z"));
    expect(parseTrvDate("2026-09-02")).toBe(Date.parse("2026-09-01T22:00:00Z"));
    expect(parseTrvDate("nonsense")).toBeUndefined();
    expect(parseTrvDate(undefined)).toBeUndefined();
  });

  it("handles the DST switch", () => {
    // 2026-03-29: clocks go from 02:00 to 03:00.
    expect(dayStart("2026-03-29")).toBe(Date.parse("2026-03-28T23:00:00Z"));
    expect(dayStart("2026-03-30")).toBe(Date.parse("2026-03-29T22:00:00Z"));
    expect(dayStart("2026-02-30")).toBeUndefined();
  });

  it("formats in Stockholm", () => {
    expect(clock(Date.parse("2026-09-02T08:05:00Z"))).toBe("10:05");
    expect(clock(undefined)).toBe("–");
    expect(stockholmDay(Date.parse("2026-09-01T22:30:00Z"))).toBe("2026-09-02");
  });

  it("writes dates the way JSONDecoder reads them", () => {
    expect(swiftDate(Date.parse("2001-01-01T00:00:00Z"))).toBe(0);
    expect(swiftDate(Date.parse("2026-09-05T08:00:00Z"))).toBe(810_288_000);
  });
});
