import { describe, it, expect } from "vitest";
import { matchRoutes, matchPath } from "react-router";
import {
  CALENDAR_PATH,
  MEAL_EDIT_PATH,
  LOGIN_PATH,
  MEAL_HISTORY_PATH,
} from "../../app/frontend/src/routes.js";

// These tests pin how react-router matches the app's route patterns.
// The patterns use the features a router upgrade is most likely to
// change: consecutive optional dynamic segments, a splat, and a
// descendant route. If an upgrade changes matching, ranking, or param
// extraction, this file fails instead of a page.

// Same shape and order as the <Routes> table in index.jsx.
const routes = [
  { path: CALENDAR_PATH },
  { path: MEAL_EDIT_PATH },
  { path: LOGIN_PATH },
];

function bestMatch(url) {
  const matches = matchRoutes(routes, url);
  return matches === null
    ? null
    : { path: matches[0].route.path, params: matches[0].params };
}

describe("route ranking", () => {
  it("sends meal URLs to the meal route", () => {
    expect(bestMatch("/meals/42/edit/").path).toBe(MEAL_EDIT_PATH);
  });

  it("sends calendar URLs to the calendar route", () => {
    expect(bestMatch("/calendar/all/2026-01-15/").path).toBe(CALENDAR_PATH);
  });

  it("sends the root and password-reset URLs to the login route", () => {
    expect(bestMatch("/").path).toBe(LOGIN_PATH);
    expect(bestMatch("/reset-password/tok-1/").path).toBe(LOGIN_PATH);
  });

  it("documents that a meal URL without /edit falls to the login route", () => {
    // Not a designed page — the login route's two optional segments
    // swallow any one- or two-segment URL. Pinned so a ranking change
    // that sends this somewhere new gets noticed.
    const match = bestMatch("/meals/42/");
    expect(match.path).toBe(LOGIN_PATH);
    expect(match.params).toEqual({ modal: "meals", token: "42" });
  });
});

describe("calendar params (three optional segments)", () => {
  it("extracts type and date with no optionals", () => {
    expect(bestMatch("/calendar/all/2026-01-15/").params).toEqual({
      type: "all",
      date: "2026-01-15",
    });
  });

  it("extracts one optional (modal)", () => {
    expect(bestMatch("/calendar/all/2026-01-15/rotations/").params).toEqual({
      type: "all",
      date: "2026-01-15",
      modal: "rotations",
    });
  });

  it("extracts two optionals — the events/new URL the calendar pushes", () => {
    expect(bestMatch("/calendar/all/2026-01-15/events/new/").params).toEqual({
      type: "all",
      date: "2026-01-15",
      modal: "events",
      view: "new",
    });
  });

  it("extracts all three optionals", () => {
    expect(
      bestMatch("/calendar/all/2026-01-15/rotations/show/10/").params,
    ).toEqual({
      type: "all",
      date: "2026-01-15",
      modal: "rotations",
      view: "show",
      id: "10",
    });
  });
});

describe("meal route (splat)", () => {
  it("extracts the meal id with an empty splat", () => {
    expect(bestMatch("/meals/42/edit/").params).toEqual({ id: "42", "*": "" });
  });

  it("keeps the history remainder in the splat", () => {
    expect(bestMatch("/meals/42/edit/history/42/").params).toEqual({
      id: "42",
      "*": "history/42/",
    });
  });
});

describe("login params (two optional segments)", () => {
  it("matches the bare root with no params", () => {
    expect(bestMatch("/").params).toEqual({});
  });

  it("extracts modal alone", () => {
    expect(bestMatch("/reset-password/").params).toEqual({
      modal: "reset-password",
    });
  });

  it("extracts modal and token", () => {
    expect(bestMatch("/reset-password/tok-1/").params).toEqual({
      modal: "reset-password",
      token: "tok-1",
    });
  });
});

describe("history descendant route", () => {
  // DateBox mounts a descendant <Routes> under the meal route; it
  // matches against the pathname left over after /meals/:id/edit.
  it("matches the history remainder", () => {
    const match = matchPath({ path: MEAL_HISTORY_PATH }, "/history/42");
    expect(match).not.toBeNull();
    expect(match.params["*"]).toBe("42");
  });

  it("does not match other remainders", () => {
    expect(matchPath({ path: MEAL_HISTORY_PATH }, "/something")).toBeNull();
  });
});
