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

// What the open calendar form holds (calendar/show.jsx): changes a
// person typed, the flag the discard gate keeps (ADR 0006), and an
// error message of its own (use_form_messages.ts, #137).
const CLEAN = { dirty: false, errorShown: false };
const TYPED = { dirty: true, errorShown: false };
const ERROR = { dirty: false, errorShown: true };

describe("pathAfterIdle", () => {
  it("sends a meal page, and its history, to today's calendar", () => {
    expect(pathAfterIdle("/meals/42/edit/", TODAY, true, CLEAN)).toBe(HOME);
    expect(pathAfterIdle("/meals/42/edit/history/", TODAY, true, CLEAN)).toBe(
      HOME,
    );
  });

  it("sends the calendar of another month to today's calendar", () => {
    expect(pathAfterIdle("/calendar/all/2026-12-01/", TODAY, true, CLEAN)).toBe(
      HOME,
    );
    expect(pathAfterIdle("/calendar/all/2026-09-30/", TODAY, true, CLEAN)).toBe(
      HOME,
    );
    // The same month a year before is another month.
    expect(pathAfterIdle("/calendar/all/2025-10-10/", TODAY, true, CLEAN)).toBe(
      HOME,
    );
  });

  it("leaves the calendar of today's month as it is, whatever day of it the address names", () => {
    expect(
      pathAfterIdle("/calendar/all/2026-10-10/", TODAY, true, CLEAN),
    ).toBeNull();
    expect(
      pathAfterIdle("/calendar/all/2026-10-01/", TODAY, true, CLEAN),
    ).toBeNull();
    expect(
      pathAfterIdle("/calendar/all/2026-10-31", TODAY, true, CLEAN),
    ).toBeNull();
  });

  // A rotation's dialog only shows a list and holds nothing anyone
  // typed, so it is closed on any month. Left open on today's month, it
  // would cover the calendar until someone closed it by hand.
  it("closes a rotation's dialog, on today's month too", () => {
    expect(
      pathAfterIdle(
        "/calendar/all/2026-10-03/rotations/show/9/",
        TODAY,
        true,
        CLEAN,
      ),
    ).toBe(HOME);
    expect(
      pathAfterIdle(
        "/calendar/all/2026-11-03/rotations/show/9/",
        TODAY,
        true,
        CLEAN,
      ),
    ).toBe(HOME);
  });

  // ADR 0006: nobody is there to answer "Discard your changes?", and a
  // form with nothing typed in it holds nothing to lose. So it closes
  // the way a calendar with no form open goes home.
  it.each(FORMS)("closes the form %s when nothing is typed in it", (form) => {
    expect(
      pathAfterIdle(`/calendar/all/2026-12-01/${form}/`, TODAY, true, CLEAN),
    ).toBe(HOME);
  });

  // The form closes, and the screen shows today's month, as it did.
  it.each(FORMS)(
    "closes the form %s on today's month too, to today's calendar",
    (form) => {
      expect(
        pathAfterIdle(`/calendar/all/2026-10-03/${form}/`, TODAY, true, CLEAN),
      ).toBe(HOME);
    },
  );

  // ADR 0006: a typed draft is never dropped without the question, and
  // nobody is there to answer it.
  it.each(FORMS)("never closes the form %s with typed changes", (form) => {
    expect(
      pathAfterIdle(`/calendar/all/2026-12-01/${form}/`, TODAY, true, TYPED),
    ).toBeNull();
    expect(
      pathAfterIdle(`/calendar/all/2026-10-10/${form}/`, TODAY, true, TYPED),
    ).toBeNull();
  });

  // #137: an error stays until a person closes it. A form's own error
  // goes with the form: a refused Delete, an Edit form whose record could
  // not be loaded (#115), a refused Create with nothing typed.
  it.each(FORMS)(
    "never closes the form %s while it shows an error of its own",
    (form) => {
      expect(
        pathAfterIdle(`/calendar/all/2026-12-01/${form}/`, TODAY, true, ERROR),
      ).toBeNull();
      expect(
        pathAfterIdle(`/calendar/all/2026-10-10/${form}/`, TODAY, true, ERROR),
      ).toBeNull();
    },
  );

  // The flag is the calendar's, so a form added to its table later is
  // held by the same rule with no change here. A dialog the table does
  // not know (a hand-typed address) shows nothing anyone can type in,
  // so it reports nothing typed and closes.
  it("holds every dialog of the calendar with typed changes or an error, and closes it without", () => {
    const dialogs = Object.entries(MODAL_FORMS).flatMap(([modal, views]) =>
      Object.keys(views).map((view) => `${modal}/${view}`),
    );
    dialogs.push("no-such-dialog");
    dialogs.forEach((dialog) => {
      const path = `/calendar/all/2026-10-10/${dialog}/5/`;
      expect(pathAfterIdle(path, TODAY, true, TYPED)).toBeNull();
      expect(pathAfterIdle(path, TODAY, true, ERROR)).toBeNull();
      expect(pathAfterIdle(path, TODAY, true, CLEAN)).toBe(HOME);
    });
  });

  // The flag is about a calendar form. Off the calendar, or on the
  // calendar with no form open, it holds nothing.
  it("does not hold a page with no form open", () => {
    expect(pathAfterIdle("/meals/42/edit/", TODAY, true, TYPED)).toBe(HOME);
    expect(pathAfterIdle("/calendar/all/2026-12-01/", TODAY, true, TYPED)).toBe(
      HOME,
    );
    expect(pathAfterIdle("/meals/42/edit/", TODAY, true, ERROR)).toBe(HOME);
    expect(pathAfterIdle("/calendar/all/2026-12-01/", TODAY, true, ERROR)).toBe(
      HOME,
    );
  });

  it("sends a calendar address with no real date to today's calendar", () => {
    expect(pathAfterIdle("/calendar/all/someday/", TODAY, true, CLEAN)).toBe(
      HOME,
    );
  });

  it("sends an address no page answers to today's calendar", () => {
    expect(pathAfterIdle("/no/such/page/", TODAY, true, CLEAN)).toBe(HOME);
  });

  // Signed out, there is no calendar to go to. The only pages are the
  // login page, which is home already, and the page a reset link opens,
  // where someone may be typing a new password.
  it("leaves every page alone when signed out", () => {
    expect(
      pathAfterIdle("/reset-password/abc123/", TODAY, false, CLEAN),
    ).toBeNull();
    expect(pathAfterIdle("/", TODAY, false, CLEAN)).toBeNull();
    expect(pathAfterIdle("/meals/42/edit/", TODAY, false, CLEAN)).toBeNull();
  });

  // Signed in, "/" is already on its way to today's calendar.
  it("leaves the login page alone when signed in", () => {
    expect(pathAfterIdle("/", TODAY, true, CLEAN)).toBeNull();
  });
});

describe("pathToLoadAfterIdle", () => {
  const CALM = {
    crashed: false,
    newVersion: false,
    errorShown: false,
    form: CLEAN,
  };
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

  // A form with nothing typed in it holds nothing to lose, so it goes
  // with the page load, the way the idle timer closes it.
  it.each(FORMS)(
    "loads today's calendar for a new version while the form %s is open with nothing typed",
    (form) => {
      expect(
        pathToLoadAfterIdle(
          `/calendar/all/2026-10-10/${form}/`,
          TODAY,
          true,
          NEW_VERSION,
        ),
      ).toBe(HOME);
    },
  );

  // ADR 0006: a typed draft is never dropped without the question.
  it.each(FORMS)(
    "loads nothing for a new version while the form %s holds typed changes",
    (form) => {
      expect(
        pathToLoadAfterIdle(`/calendar/all/2026-10-10/${form}/`, TODAY, true, {
          ...NEW_VERSION,
          form: TYPED,
        }),
      ).toBeNull();
    },
  );

  // #137: the load would take the form's own error away unread.
  it.each(FORMS)(
    "loads nothing for a new version while the form %s shows an error of its own",
    (form) => {
      expect(
        pathToLoadAfterIdle(`/calendar/all/2026-10-10/${form}/`, TODAY, true, {
          ...NEW_VERSION,
          form: ERROR,
        }),
      ).toBeNull();
    },
  );

  // The flag is about a calendar form, so it holds no other page.
  it("loads a new version on a page with no form open, whatever the flag says", () => {
    expect(
      pathToLoadAfterIdle("/meals/42/edit/", TODAY, true, {
        ...NEW_VERSION,
        form: TYPED,
      }),
    ).toBe(HOME);
    expect(
      pathToLoadAfterIdle("/meals/42/edit/", TODAY, true, {
        ...NEW_VERSION,
        form: ERROR,
      }),
    ).toBe(HOME);
  });

  // The error page took the place of every form, and the form reported
  // nothing typed and no error as it went (use_dirty_report.js,
  // use_form_messages.ts). So a flag still set can only be one the store
  // failed to clear, and the crashed page must not wait on it.
  it("loads today's calendar after a crash whatever the flags say", () => {
    expect(
      pathToLoadAfterIdle("/calendar/all/2026-10-10/events/new/", TODAY, true, {
        ...CRASHED,
        form: TYPED,
      }),
    ).toBe(HOME);
    expect(
      pathToLoadAfterIdle("/calendar/all/2026-10-10/events/new/", TODAY, true, {
        ...CRASHED,
        form: ERROR,
      }),
    ).toBe(HOME);
  });

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
    const both = {
      crashed: true,
      newVersion: true,
      errorShown: true,
      form: CLEAN,
    };
    expect(
      pathToLoadAfterIdle("/meals/42/edit/", TODAY, true, both),
    ).toBeNull();
    expect(pathToLoadAfterIdle("/", TODAY, false, both)).toBeNull();
  });
});

describe("pathAfterNewDay", () => {
  it("moves the calendar of the old day's month to the new day's month", () => {
    expect(
      pathAfterNewDay(
        "/calendar/all/2026-10-15/",
        "2026-10-31",
        "2026-11-01",
        CLEAN,
      ),
    ).toBe("/calendar/all/2026-11-01/");
    expect(
      pathAfterNewDay(
        "/calendar/all/2026-12-31/",
        "2026-12-31",
        "2027-01-01",
        CLEAN,
      ),
    ).toBe("/calendar/all/2027-01-01/");
  });

  // A zone change can move today back across the first of a month.
  it("moves back a month when the new day is in the month before", () => {
    expect(
      pathAfterNewDay(
        "/calendar/all/2026-11-01/",
        "2026-11-01",
        "2026-10-31",
        CLEAN,
      ),
    ).toBe("/calendar/all/2026-10-31/");
  });

  it("leaves the calendar alone when the new day is in the same month", () => {
    expect(
      pathAfterNewDay(
        "/calendar/all/2026-10-10/",
        "2026-10-10",
        "2026-10-11",
        CLEAN,
      ),
    ).toBeNull();
  });

  // Someone paged to another month on purpose.
  it("leaves a calendar of another month alone", () => {
    expect(
      pathAfterNewDay(
        "/calendar/all/2026-12-01/",
        "2026-10-31",
        "2026-11-01",
        CLEAN,
      ),
    ).toBeNull();
    expect(
      pathAfterNewDay(
        "/calendar/all/2026-11-05/",
        "2026-10-31",
        "2026-11-01",
        CLEAN,
      ),
    ).toBeNull();
  });

  // ADR 0006: a typed draft is never dropped without the question.
  it.each(FORMS)("never moves the form %s with typed changes", (form) => {
    expect(
      pathAfterNewDay(
        `/calendar/all/2026-10-31/${form}/`,
        "2026-10-31",
        "2026-11-01",
        TYPED,
      ),
    ).toBeNull();
  });

  // #137: the move would close the form and take its error away unread.
  it.each(FORMS)(
    "never moves the form %s while it shows an error of its own",
    (form) => {
      expect(
        pathAfterNewDay(
          `/calendar/all/2026-10-31/${form}/`,
          "2026-10-31",
          "2026-11-01",
          ERROR,
        ),
      ).toBeNull();
    },
  );

  // A form with nothing typed in it holds nothing to lose, so the
  // calendar moves as it does with no form open, and the form closes.
  it.each(FORMS)(
    "moves the calendar under the form %s with nothing typed, and closes it",
    (form) => {
      expect(
        pathAfterNewDay(
          `/calendar/all/2026-10-31/${form}/`,
          "2026-10-31",
          "2026-11-01",
          CLEAN,
        ),
      ).toBe("/calendar/all/2026-11-01/");
    },
  );

  // The same rule as with no form open: only the month that held the
  // old day moves, so a form on another month stays open.
  it("leaves a form with nothing typed open when its month does not move", () => {
    expect(
      pathAfterNewDay(
        "/calendar/all/2026-12-01/events/new/",
        "2026-10-31",
        "2026-11-01",
        CLEAN,
      ),
    ).toBeNull();
    expect(
      pathAfterNewDay(
        "/calendar/all/2026-10-10/events/new/",
        "2026-10-10",
        "2026-10-11",
        CLEAN,
      ),
    ).toBeNull();
  });

  it("moves a calendar with a rotation's dialog, which is not a form", () => {
    expect(
      pathAfterNewDay(
        "/calendar/all/2026-10-31/rotations/show/9/",
        "2026-10-31",
        "2026-11-01",
        CLEAN,
      ),
    ).toBe("/calendar/all/2026-11-01/");
  });

  it("leaves every page that is not the calendar alone", () => {
    expect(
      pathAfterNewDay("/meals/42/edit/", "2026-10-31", "2026-11-01", CLEAN),
    ).toBeNull();
    expect(pathAfterNewDay("/", "2026-10-31", "2026-11-01", CLEAN)).toBeNull();
  });
});
