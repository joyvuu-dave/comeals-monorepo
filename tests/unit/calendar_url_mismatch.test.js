import { describe, it, expect, vi } from "vitest";
import { matchPath } from "react-router";

// calendar/show.jsx calls Modal.setAppElement("#root") at import time.
vi.hoisted(() => {
  const root = document.createElement("div");
  root.id = "root";
  document.body.appendChild(root);
});

import calendarFixture from "../fixtures/calendar.json";
import {
  CALENDAR_PATH,
  MEAL_EDIT_PATH,
} from "../../app/frontend/src/routes.js";
import { MODAL_FORMS } from "../../app/frontend/src/components/calendar/show.jsx";

// A click on a calendar chip navigates to the chip's url
// (handleSelectEvent in calendar/show.jsx). The server writes the urls
// (app/serializers/calendar_serializer.rb), and tests/fixtures/calendar.json
// is its real output (rake test:generate_fixtures). Each url must open a
// screen the SPA has. The Ruby serializer specs pin the exact strings;
// this is the one check that the SPA can open them.
//
// A relative url opens a modal over the calendar: react-router resolves
// it against the calendar page, and the calendar looks up
// MODAL_FORMS[modal][view]. A name it does not list (say, with
// underscores) opens an empty dialog. An absolute url is a page.
const CALENDAR_PAGE = "/calendar/all/2026-01-15";
const WHOLE_NUMBER = /^\d+$/;

function screenFor(url) {
  if (url.startsWith("/")) {
    const meal = matchPath(MEAL_EDIT_PATH, url);
    return meal && WHOLE_NUMBER.test(meal.params.id) ? "meal page" : null;
  }
  const match = matchPath(CALENDAR_PATH, `${CALENDAR_PAGE}/${url}`);
  if (!match) return null;
  const { modal, view, id } = match.params;
  if (!MODAL_FORMS[modal]?.[view] || !WHOLE_NUMBER.test(id ?? "")) {
    return null;
  }
  return `${modal}/${view}`;
}

// What a click on each kind of chip opens.
const SCREENS = {
  meals: "meal page",
  bills: "meal page",
  rotations: "rotations/show",
  common_house_reservations: "common-house-reservations/edit",
  guest_room_reservations: "guest-room-reservations/edit",
  events: "events/edit",
};

describe("calendar chip urls open a screen the SPA has", () => {
  it("the fixture has every kind of chip, none of them empty", () => {
    const arrays = Object.keys(calendarFixture).filter((key) =>
      Array.isArray(calendarFixture[key]),
    );

    expect(arrays.sort()).toEqual(
      [...Object.keys(SCREENS), "birthdays"].sort(),
    );
    arrays.forEach((key) => {
      expect(calendarFixture[key].length).toBeGreaterThan(0);
    });
  });

  it.each(Object.entries(SCREENS))("%s open the %s", (key, screen) => {
    calendarFixture[key].forEach((event) => {
      expect(screenFor(event.url)).toBe(screen);
    });
  });

  it("birthdays have no url, so a click opens nothing", () => {
    calendarFixture.birthdays.forEach((event) => {
      expect(event).not.toHaveProperty("url");
    });
  });

  // The check above can fail: these are the urls a wrong serializer
  // could send.
  it("finds no screen for a name, view or id the SPA does not have", () => {
    expect(screenFor("guest_room_reservations/edit/60")).toBeNull();
    expect(screenFor("common_house_reservations/edit/50")).toBeNull();
    expect(screenFor("events/show/70")).toBeNull();
    expect(screenFor("rotations/edit/10")).toBeNull();
    expect(screenFor("events/edit/seventy")).toBeNull();
    expect(screenFor("events/edit")).toBeNull();
    expect(screenFor("/meals/41")).toBeNull();
    expect(screenFor("/meals/abc/edit")).toBeNull();
  });
});
