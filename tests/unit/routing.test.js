import { describe, it, expect } from "vitest";
import { matchRoutes, matchPath } from "react-router";
import {
  PAGES,
  CALENDAR_PATH,
  MEAL_EDIT_PATH,
  MEAL_HISTORY_PATH,
  LOGIN_PATH,
  RESET_PASSWORD_PATH,
  CONFIRM_EMAIL_PATH,
  NOT_FOUND_PATH,
} from "../../app/frontend/src/routes.js";

// These tests pin how react-router matches the app's pages, the ones in
// routes.json. If an upgrade changes matching, ranking, or param
// extraction, this file fails instead of a page. Whether the server
// agrees with react-router on every path is checked by
// spec/lib/app_pages_contract_spec.rb, which asks react-router itself.

// Same shape and order as AppRoutes (components/app/app_routes.tsx).
const routes = [
  ...Object.values(PAGES).map((page) => ({ path: page.path })),
  { path: NOT_FOUND_PATH },
];

function bestMatch(url) {
  const matches = matchRoutes(routes, url);
  return { path: matches[0].route.path, params: matches[0].params };
}

describe("the list of pages", () => {
  it("names the patterns the code uses", () => {
    expect(LOGIN_PATH).toBe("/");
    expect(RESET_PASSWORD_PATH).toBe("/reset-password");
    expect(CONFIRM_EMAIL_PATH).toBe("/confirm-email");
    expect(CALENDAR_PATH).toBe("/calendar/:type/:date/:modal?/:view?/:id?");
    expect(MEAL_EDIT_PATH).toBe("/meals/:id/edit/history?");
    expect(MEAL_HISTORY_PATH).toBe("/meals/:id/edit/history");
  });

  // Each example opens its own page, so the server's check after a
  // deploy and the e2e test that opens every example test that page.
  it.each(
    Object.entries(PAGES).flatMap(([name, page]) =>
      page.examples.map((example) => [name, example]),
    ),
  )("sends the %s page's example %s to that page", (name, example) => {
    expect(bestMatch(example).path).toBe(PAGES[name].path);
  });

  it("gives every page at least one example", () => {
    for (const [name, page] of Object.entries(PAGES)) {
      expect(page.examples.length, name).toBeGreaterThan(0);
    }
  });

  // A * would make every address under it a page, so a typo there
  // would get a 200. lib/app_pages.rb refuses it too.
  it("has no pattern that takes the rest of the path", () => {
    for (const page of Object.values(PAGES)) {
      expect(page.path).not.toContain("*");
    }
  });
});

describe("addresses that are not pages", () => {
  it.each([
    "/login",
    "/calendar",
    "/calendar/all",
    "/calendar/all/2026-01-15/a/b/c/d",
    "/meals/42",
    "/meals/42/edit/nothing",
    "/reset-password/tok-1",
    "/confirm-email/tok-1",
    "/.well-known/security.txt",
    "/foo.json",
    "/a/b/c/d",
  ])("sends %s to Page not found", (url) => {
    expect(bestMatch(url).path).toBe(NOT_FOUND_PATH);
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

describe("the meal page, with the history box open or not", () => {
  it("extracts the meal id with the box closed", () => {
    expect(bestMatch("/meals/42/edit/")).toEqual({
      path: MEAL_EDIT_PATH,
      params: { id: "42" },
    });
  });

  it("extracts the meal id with the box open", () => {
    expect(bestMatch("/meals/42/edit/history/")).toEqual({
      path: MEAL_EDIT_PATH,
      params: { id: "42" },
    });
  });

  it("tells the box open from closed with MEAL_HISTORY_PATH", () => {
    expect(matchPath(MEAL_HISTORY_PATH, "/meals/42/edit/history/")).not.toBe(
      null,
    );
    expect(matchPath(MEAL_HISTORY_PATH, "/meals/42/edit/HISTORY")).not.toBe(
      null,
    );
    expect(matchPath(MEAL_HISTORY_PATH, "/meals/42/edit/")).toBe(null);
  });
});

describe("the login pages", () => {
  it("sends each to its own route, with no params", () => {
    expect(bestMatch("/")).toEqual({ path: LOGIN_PATH, params: {} });
    expect(bestMatch("/reset-password/")).toEqual({
      path: RESET_PASSWORD_PATH,
      params: {},
    });
    expect(bestMatch("/confirm-email/")).toEqual({
      path: CONFIRM_EMAIL_PATH,
      params: {},
    });
  });
});
