import { describe, it, expect, vi } from "vitest";

vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));
import Cookie from "js-cookie";

import {
  communityApiPath,
  isCommonHouse,
  signedIn,
} from "../../../app/frontend/src/helpers/session";

// The session cookies are read at the moment a request is built, and a
// request that needs them is not sent when they are gone (#153).
describe("session", () => {
  it("builds a community path from the community id", () => {
    Cookie.set("community_id", "7");

    expect(communityApiPath("hosts")).toBe("/api/v1/communities/7/hosts");
    expect(communityApiPath("calendar/2026-01-15")).toBe(
      "/api/v1/communities/7/calendar/2026-01-15",
    );
  });

  // js-cookie writes String(value), so a cookie set from a missing value
  // holds the text "undefined".
  it("builds no community path without a community id, or with the text undefined", () => {
    Cookie.remove("community_id");
    expect(communityApiPath("hosts")).toBeNull();

    Cookie.set("community_id", "undefined");
    expect(communityApiPath("hosts")).toBeNull();
  });

  it("is signed in only with a token", () => {
    Cookie.set("token", "abc");
    expect(signedIn()).toBe(true);

    Cookie.set("token", "undefined");
    expect(signedIn()).toBe(false);

    Cookie.remove("token");
    expect(signedIn()).toBe(false);
  });

  // The sign-in answer of the Common House screen has common_house: true,
  // and login.jsx keeps it as the text "true". A resident's answer has
  // no such field, so the page has no such cookie.
  it("is the Common House screen only with the cookie the sign-in wrote", () => {
    Cookie.set("common_house", "true");
    expect(isCommonHouse()).toBe(true);

    Cookie.remove("common_house");
    expect(isCommonHouse()).toBe(false);

    Cookie.set("common_house", "undefined");
    expect(isCommonHouse()).toBe(false);
  });
});
