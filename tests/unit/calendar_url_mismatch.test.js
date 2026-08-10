import { describe, it, expect } from "vitest";
import calendarFixture from "../fixtures/calendar.json";

describe("Calendar event URL / modal routing compatibility", () => {
  // renderModal in calendar/show.jsx accepts both hyphenated and underscored resource names.
  const VALID_MODAL_NAMES = [
    "guest-room-reservations",
    "guest_room_reservations",
    "common-house-reservations",
    "common_house_reservations",
    "events",
  ];

  // The serializers emit relative URLs ("events/edit/70"). The calendar
  // page navigates to them from /calendar/:type/:date, so react-router
  // resolves them to /calendar/:type/:date/:resource/:view/:id and
  // renderModal switches on the resource segment. Mirror that resolution:
  // the resource is the first segment of the relative URL.
  function extractResource(url) {
    expect(url).not.toMatch(/^\//); // relative on purpose — see above
    return url.split("/")[0];
  }

  it("common_house_reservations fixture URL matches modal routing", () => {
    const event = calendarFixture.common_house_reservations[0];
    expect(VALID_MODAL_NAMES).toContain(extractResource(event.url));
  });

  it("guest_room_reservations fixture URL matches modal routing", () => {
    const event = calendarFixture.guest_room_reservations[0];
    expect(VALID_MODAL_NAMES).toContain(extractResource(event.url));
  });

  it("events fixture URL matches modal routing", () => {
    const event = calendarFixture.events[0];
    expect(extractResource(event.url)).toBe("events");
  });
});
