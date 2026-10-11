import { describe, expect, it } from "vitest";
import { alertBody, alertTitle, evaluate } from "../src/alerts.js";
import { StationNames } from "../src/contentState.js";
import type { Snapshot } from "../src/snapshot.js";

// Mirrors the TrainAlertEngine cases in TagradarTests/TrainSnapshotTests.swift.

function snap(delayMinutes: number | undefined, status: Snapshot["status"] = "scheduled", track = "1"): Snapshot {
  return {
    ident: "837",
    productName: "SJ Snabbtåg",
    status,
    delay: delayMinutes === undefined ? undefined : delayMinutes * 60,
    originTrack: track,
    originSignature: "U",
    destinationSignature: "Suc",
    expectedDeparture: Date.parse("2026-09-05T08:49:00Z"),
    progress: 0,
    upcomingStops: [],
  };
}

describe("alert rules", () => {
  it("sets a baseline without alerting", () => {
    expect(evaluate(undefined, snap(12)).alerts).toEqual([]);
  });

  it("alerts on a delay of five minutes or more, and back on time", () => {
    const { state } = evaluate(undefined, snap(0));
    const late = evaluate(state, snap(7));
    expect(late.alerts).toEqual([{ kind: "delay", minutes: 7 }]);
    expect(evaluate(late.state, snap(9)).alerts).toEqual([]);
    expect(evaluate(late.state, snap(1)).alerts).toEqual([{ kind: "backOnTime" }]);
  });

  it("keeps the reference when the change is small", () => {
    const { state } = evaluate(undefined, snap(0));
    const small = evaluate(state, snap(3));
    expect(small.alerts).toEqual([]);
    expect(small.state.delayMinutes).toBe(0);
    expect(evaluate(small.state, snap(5)).alerts).toEqual([{ kind: "delay", minutes: 5 }]);
  });

  it("reports cancellation, track changes before boarding and arrival once", () => {
    const { state } = evaluate(undefined, snap(0));
    expect(evaluate(state, snap(undefined, "canceled")).alerts).toEqual([{ kind: "canceled" }]);
    expect(evaluate(state, snap(0, "scheduled", "2")).alerts).toEqual([{ kind: "trackChanged", from: "1", to: "2" }]);
    const boarded = evaluate(state, snap(0, "enRoute")).state;
    expect(evaluate(boarded, snap(0, "enRoute", "2")).alerts).toEqual([]);
    const arrived = evaluate(boarded, snap(2, "arrived"));
    expect(arrived.alerts).toEqual([{ kind: "arrived", delayMinutes: 2 }]);
    expect(evaluate(arrived.state, snap(30, "enRoute")).alerts).toEqual([]);
  });

  it("rounds half-minutes away from zero like Swift", () => {
    expect(evaluate(undefined, { ...snap(0), delay: 150 }).state.delayMinutes).toBe(3);
    expect(evaluate(undefined, { ...snap(0), delay: -150 }).state.delayMinutes).toBe(-3);
  });
});

describe("alert texts", () => {
  const names = new StationNames(new Map([["U", { name: "Uppsala C", shortName: "Uppsala" }]]));

  it("uses loc-keys that exist in Localizable.xcstrings", () => {
    expect(alertBody({ kind: "delay", minutes: 7 }, snap(7), names)).toEqual({
      "loc-key": "Now %@ min late. New departure %@ from %@.",
      "loc-args": ["7", "10:49", "Uppsala"],
    });
    expect(alertBody({ kind: "trackChanged", from: "1", to: "2" }, snap(0), names)["loc-args"]).toEqual(["1", "2", "Uppsala"]);
    expect(alertTitle(snap(0))).toEqual({ "loc-key": "%@ %@", "loc-args": ["SJ Snabbtåg", "837"] });
    expect(alertTitle({ ...snap(0), productName: undefined })).toEqual({ "loc-key": "Train %@", "loc-args": ["837"] });
  });
});
