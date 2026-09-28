import { describe, it, expect } from "vitest";
import { zonedInstant } from "../helpers/zoned_time.js";
import { useDeviceZone } from "./helpers/device_zone.js";

// The integration suite freezes the browser at noon in Los Angeles on
// its frozen day (tests/helpers/integration_setup.js), and the viewer
// time zone test at 23:30. The answer must not depend on the zone of
// the machine running the suite. Each block sets that zone itself.
describe.each([
  "America/Chicago",
  "America/New_York",
  "America/Los_Angeles",
  "UTC",
  "Asia/Tokyo",
  "Europe/London",
])("zonedInstant on a machine in %s", (machineZone) => {
  useDeviceZone(machineZone);

  it.each([
    ["2026-01-15T12:00", "2026-01-15T20:00:00.000Z"],
    ["2026-01-15T23:30", "2026-01-16T07:30:00.000Z"],
    ["2026-03-08T00:30", "2026-03-08T08:30:00.000Z"],
    ["2026-03-08T12:00", "2026-03-08T19:00:00.000Z"],
    ["2026-10-24T19:00", "2026-10-25T02:00:00.000Z"],
    ["2026-11-01T00:00", "2026-11-01T07:00:00.000Z"],
    ["2026-11-01T12:00", "2026-11-01T20:00:00.000Z"],
  ])("finds %s in Los Angeles at %s", (wallClock, instant) => {
    expect(zonedInstant(wallClock, "America/Los_Angeles").toISOString()).toBe(
      instant,
    );
  });

  it("refuses a time the clocks skip", () => {
    expect(() =>
      zonedInstant("2026-03-08T02:30", "America/Los_Angeles"),
    ).toThrow("2026-03-08T02:30 happens 0 times in America/Los_Angeles");
  });

  it("refuses a time the clocks show twice", () => {
    expect(() =>
      zonedInstant("2026-11-01T01:30", "America/Los_Angeles"),
    ).toThrow("2026-11-01T01:30 happens 2 times in America/Los_Angeles");
  });
});
