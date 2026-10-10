import { describe, it, expect, vi } from "vitest";

// calendar/show.jsx calls Modal.setAppElement("#root") when it loads.
vi.hoisted(() => {
  const root = document.createElement("div");
  root.id = "root";
  document.body.appendChild(root);
});

import {
  pathAfterIdle,
  pathAfterNewDay,
  pathToLoadAfterIdle,
} from "../../../app/frontend/src/helpers/screen_home";
import { MODAL_FORMS } from "../../../app/frontend/src/components/calendar/show.jsx";

// Where the shared screen goes when nobody has used it for five
// minutes, and where the calendar goes when the community's day changes
// (components/app/back_to_today.tsx). Today is Oct 10, 2026.
const TODAY = "2026-10-10";
const HOME = "/calendar/all/2026-10-10/";

// Every calendar form of ADR 0006, as the sidebar and the chips open it.
const FORMS = [
  "guest-room-reservations/new",
  "guest-room-reservations/edit/5",
  "common-house-reservations/new",
  "common-house-reservations/edit/5",
  "events/new",
  "events/edit/5",
];

describe("pathAfterIdle", () => {
  it("sends a meal page, and its history, to today's calendar", () => {
    expect(pathAfterIdle("/meals/42/edit/", TODAY, true)).toBe(HOME);
    expect(pathAfterIdle("/meals/42/edit/history/", TODAY, true)).toBe(HOME);
  });

  it("sends the calendar of another month to today's calendar", () => {
    expect(pathAfterIdle("/calendar/all/2026-12-01/", TODAY, true)).toBe(HOME);
    expect(pathAfterIdle("/calendar/all/2026-09-30/", TODAY, true)).toBe(HOME);
    // The same month a year before is another month.
    expect(pathAfterIdle("/calendar/all/2025-10-10/", TODAY, true)).toBe(HOME);
  });

  it("leaves the calendar of today's month as it is, whatever day of it the address names", () => {
    expect(pathAfterIdle("/calendar/all/2026-10-10/", TODAY, true)).toBeNull();
    expect(pathAfterIdle("/calendar/all/2026-10-01/", TODAY, true)).toBeNull();
    expect(pathAfterIdle("/calendar/all/2026-10-31", TODAY, true)).toBeNull();
  });

  // A rotation's dialog only shows a list and holds nothing anyone
  // typed, so it is closed on any month. Left open on today's month, it
  // would cover the calendar until someone closed it by hand.
  it("closes a rotation's dialog, on today's month too", () => {
    expect(
      pathAfterIdle("/calendar/all/2026-10-03/rotations/show/9/", TODAY, true),
    ).toBe(HOME);
    expect(
      pathAfterIdle("/calendar/all/2026-11-03/rotations/show/9/", TODAY, true),
    ).toBe(HOME);
  });

  // Read from the calendar's own table of dialogs, so a form added
  // there later is held without a change here. Only the rotation list
  // may be closed. A dialog the table does not know (a hand-typed
  // address) is held too.
  it("holds every dialog of the calendar but the rotation list", () => {
    const dialogs = Object.entries(MODAL_FORMS).flatMap(([modal, views]) =>
      Object.keys(views).map((view) => `${modal}/${view}`),
    );
    expect(dialogs).toContain("rotations/show");
    dialogs.forEach((dialog) => {
      const path = `/calendar/all/2026-10-10/${dialog}/5/`;
      expect(pathAfterIdle(path, TODAY, true)).toBe(
        dialog === "rotations/show" ? HOME : null,
      );
    });
    expect(
      pathAfterIdle("/calendar/all/2026-10-10/no-such-dialog/", TODAY, true),
    ).toBeNull();
  });

  // ADR 0006: a form is a draft until Create or Update, so the timer
  // never closes one, on any month.
  it.each(FORMS)("never closes the form %s", (form) => {
    expect(
      pathAfterIdle(`/calendar/all/2026-12-01/${form}/`, TODAY, true),
    ).toBeNull();
    expect(
      pathAfterIdle(`/calendar/all/2026-10-10/${form}/`, TODAY, true),
    ).toBeNull();
  });

  it("sends a calendar address with no real date to today's calendar", () => {
    expect(pathAfterIdle("/calendar/all/someday/", TODAY, true)).toBe(HOME);
  });

  it("sends an address no page answers to today's calendar", () => {
    expect(pathAfterIdle("/no/such/page/", TODAY, true)).toBe(HOME);
  });

  // Signed out, there is no calendar to go to. The only pages are the
  // login page, which is home already, and the page a reset link opens,
  // where someone may be typing a new password.
  it("leaves every page alone when signed out", () => {
    expect(pathAfterIdle("/reset-password/abc123/", TODAY, false)).toBeNull();
    expect(pathAfterIdle("/", TODAY, false)).toBeNull();
    expect(pathAfterIdle("/meals/42/edit/", TODAY, false)).toBeNull();
  });

  // Signed in, "/" is already on its way to today's calendar.
  it("leaves the login page alone when signed in", () => {
    expect(pathAfterIdle("/", TODAY, true)).toBeNull();
  });
});

describe("pathToLoadAfterIdle", () => {
  const CALM = { crashed: false, newVersion: false, errorShown: false };
  const CRASHED = { ...CALM, crashed: true };
  const NEW_VERSION = { ...CALM, newVersion: true };

  it("loads nothing when the page did not crash and the code is current", () => {
    expect(
      pathToLoadAfterIdle("/meals/42/edit/", TODAY, true, CALM),
    ).toBeNull();
    expect(
      pathToLoadAfterIdle("/calendar/all/2026-12-01/", TODAY, true, CALM),
    ).toBeNull();
  });

  // The error page stays when the address changes, so a move inside the
  // app would leave "Something went wrong" on screen.
  it("loads today's calendar after a crash, from any page", () => {
    expect(pathToLoadAfterIdle("/meals/42/edit/", TODAY, true, CRASHED)).toBe(
      HOME,
    );
    // The calendar of today's month too: a move would not happen at all.
    expect(
      pathToLoadAfterIdle("/calendar/all/2026-10-10/", TODAY, true, CRASHED),
    ).toBe(HOME);
    // The error page took the place of the form, so nothing typed is
    // lost.
    expect(
      pathToLoadAfterIdle(
        "/calendar/all/2026-10-10/events/new/",
        TODAY,
        true,
        CRASHED,
      ),
    ).toBe(HOME);
  });

  it("loads the login page after a crash when signed out", () => {
    expect(
      pathToLoadAfterIdle("/reset-password/abc123/", TODAY, false, CRASHED),
    ).toBe("/");
    expect(pathToLoadAfterIdle("/", TODAY, false, CRASHED)).toBe("/");
  });

  // Without a page load, the screen runs the old code until someone
  // taps Refresh.
  it("loads today's calendar when a new version is out, from any page", () => {
    expect(
      pathToLoadAfterIdle("/meals/42/edit/", TODAY, true, NEW_VERSION),
    ).toBe(HOME);
    expect(
      pathToLoadAfterIdle(
        "/calendar/all/2026-12-01/",
        TODAY,
        true,
        NEW_VERSION,
      ),
    ).toBe(HOME);
    expect(
      pathToLoadAfterIdle(
        "/calendar/all/2026-10-10/",
        TODAY,
        true,
        NEW_VERSION,
      ),
    ).toBe(HOME);
    expect(
      pathToLoadAfterIdle(
        "/calendar/all/2026-10-03/rotations/show/9/",
        TODAY,
        true,
        NEW_VERSION,
      ),
    ).toBe(HOME);
  });

  // ADR 0006: a form is a draft until Create or Update.
  it.each(FORMS)(
    "loads nothing for a new version while the form %s is open",
    (form) => {
      expect(
        pathToLoadAfterIdle(
          `/calendar/all/2026-10-10/${form}/`,
          TODAY,
          true,
          NEW_VERSION,
        ),
      ).toBeNull();
    },
  );

  // Login loads the page again by itself. The page a reset link opens
  // may hold a new password someone is typing.
  it("loads nothing for a new version when signed out", () => {
    expect(
      pathToLoadAfterIdle("/reset-password/abc123/", TODAY, false, NEW_VERSION),
    ).toBeNull();
    expect(pathToLoadAfterIdle("/", TODAY, false, NEW_VERSION)).toBeNull();
  });

  // #137: an error stays until a person closes it, and a page load
  // takes every message away.
  it("loads nothing while an error message is on screen", () => {
    const both = { crashed: true, newVersion: true, errorShown: true };
    expect(
      pathToLoadAfterIdle("/meals/42/edit/", TODAY, true, both),
    ).toBeNull();
    expect(pathToLoadAfterIdle("/", TODAY, false, both)).toBeNull();
  });
});

describe("pathAfterNewDay", () => {
  it("moves the calendar of the old day's month to the new day's month", () => {
    expect(
      pathAfterNewDay("/calendar/all/2026-10-15/", "2026-10-31", "2026-11-01"),
    ).toBe("/calendar/all/2026-11-01/");
    expect(
      pathAfterNewDay("/calendar/all/2026-12-31/", "2026-12-31", "2027-01-01"),
    ).toBe("/calendar/all/2027-01-01/");
  });

  // A zone change can move today back across the first of a month.
  it("moves back a month when the new day is in the month before", () => {
    expect(
      pathAfterNewDay("/calendar/all/2026-11-01/", "2026-11-01", "2026-10-31"),
    ).toBe("/calendar/all/2026-10-31/");
  });

  it("leaves the calendar alone when the new day is in the same month", () => {
    expect(
      pathAfterNewDay("/calendar/all/2026-10-10/", "2026-10-10", "2026-10-11"),
    ).toBeNull();
  });

  // Someone paged to another month on purpose.
  it("leaves a calendar of another month alone", () => {
    expect(
      pathAfterNewDay("/calendar/all/2026-12-01/", "2026-10-31", "2026-11-01"),
    ).toBeNull();
    expect(
      pathAfterNewDay("/calendar/all/2026-11-05/", "2026-10-31", "2026-11-01"),
    ).toBeNull();
  });

  it.each(FORMS)("never moves the form %s", (form) => {
    expect(
      pathAfterNewDay(
        `/calendar/all/2026-10-31/${form}/`,
        "2026-10-31",
        "2026-11-01",
      ),
    ).toBeNull();
  });

  it("moves a calendar with a rotation's dialog, which is not a form", () => {
    expect(
      pathAfterNewDay(
        "/calendar/all/2026-10-31/rotations/show/9/",
        "2026-10-31",
        "2026-11-01",
      ),
    ).toBe("/calendar/all/2026-11-01/");
  });

  it("leaves every page that is not the calendar alone", () => {
    expect(
      pathAfterNewDay("/meals/42/edit/", "2026-10-31", "2026-11-01"),
    ).toBeNull();
    expect(pathAfterNewDay("/", "2026-10-31", "2026-11-01")).toBeNull();
  });
});
