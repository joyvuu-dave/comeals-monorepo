import { describe, it, expect, vi } from "vitest";
import fs from "node:fs";
import path from "node:path";

// calendar/show.jsx calls Modal.setAppElement("#root") at import time.
vi.hoisted(() => {
  const root = document.createElement("div");
  root.id = "root";
  document.body.appendChild(root);
});

import {
  CALENDAR_PATH,
  LOGIN_PATH,
  MEAL_EDIT_PATH,
  MEAL_HISTORY_PATH,
  RESET_PASSWORD_MODAL,
} from "../../app/frontend/src/routes.js";
import { MODAL_FORMS } from "../../app/frontend/src/components/calendar/show.jsx";

// Every screen of the app has a golden image in the visual suite
// (tests/e2e/visual.spec.js), the way every line has a unit test. The
// screens are listed from the routes and the calendar's modal table, not
// copied from the visual spec, so a new modal fails here until its
// goldens exist. spec/admin/visual_goldens_spec.rb does the same for
// the admin pages.
const SNAPSHOTS = path.join(__dirname, "..", "e2e", "visual.spec.js-snapshots");
const BROWSERS = ["chromium", "webkit"];
const PLATFORMS = ["darwin", "linux"];

// Screen id -> the golden's base name in the visual spec.
const GOLDENS = {
  login: "login-page",
  [`login/${RESET_PASSWORD_MODAL}`]: "password-reset",
  calendar: "calendar-month",
  "calendar/guest-room-reservations/new": "guest-room-form",
  "calendar/guest-room-reservations/edit": "guest-room-edit",
  "calendar/common-house-reservations/new": "common-house-form",
  "calendar/common-house-reservations/edit": "common-house-edit",
  "calendar/events/new": "event-form",
  "calendar/events/edit": "event-edit",
  "calendar/rotations/show": "rotation-modal",
  meal: "meal-edit",
  "meal/history": "meal-history",
};

function screens() {
  const list = ["login", `login/${RESET_PASSWORD_MODAL}`, "calendar"];
  for (const [modal, views] of Object.entries(MODAL_FORMS)) {
    for (const view of Object.keys(views)) {
      list.push(`calendar/${modal}/${view}`);
    }
  }
  list.push("meal", `meal/${MEAL_HISTORY_PATH.replace("/*", "")}`);
  return list;
}

describe("every screen has a golden image", () => {
  it("lists the screens from the routes, not by hand", () => {
    // The routes these screens hang off. A changed pattern means the
    // list above needs a look.
    expect(LOGIN_PATH).toBe("/:modal?/:token?");
    expect(CALENDAR_PATH).toBe("/calendar/:type/:date/:modal?/:view?/:id?");
    expect(MEAL_EDIT_PATH).toBe("/meals/:id/edit/*");
    expect(screens()).toHaveLength(12);
  });

  it("names a golden for every screen, and no golden for a screen that is gone", () => {
    expect(Object.keys(GOLDENS).sort()).toEqual(screens().sort());
  });

  it("has the golden files for every browser and platform", () => {
    const missing = [];
    for (const golden of Object.values(GOLDENS)) {
      for (const browser of BROWSERS) {
        for (const platform of PLATFORMS) {
          const file = `${golden}-${browser}-${platform}.png`;
          if (!fs.existsSync(path.join(SNAPSHOTS, file))) missing.push(file);
        }
      }
    }
    expect(missing).toEqual([]);
  });
});
