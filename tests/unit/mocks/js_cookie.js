// The shared js-cookie mock. Use it with the redirect form:
//
//   vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));
//
// The default fixture is a signed-in session in the Pacific-timezone
// test community. A file that needs a different session replaces (or
// mutates) the fixture at the top of the file or inside a test:
//
//   import { cookies } from "../mocks/js_cookie.js";
//   cookies.current = { community_id: "7" };          // whole file
//   delete cookies.current.token;                     // one test
//
// It acts like the browser's cookie jar: `get` reads the fixture at call
// time, `set` writes to it and `remove` deletes from it, so a test can
// check what the app reads after it writes a cookie (the zone a month
// payload changes, the token logout removes). tests/unit/helpers/
// render_setup.js puts the file's fixture back after every test, so a
// write in one test cannot reach the next one.
import { vi } from "vitest";

export const cookies = {
  current: {
    token: "test-token",
    community_id: "test-community-id",
    // Fixture community is Pacific. Timezone-sensitive assertions
    // (event date conversion, etc.) read this via
    // getCommunityTimezone() — the helpers themselves work for any
    // IANA tz; see helpers.test.js.
    timezone: "America/Los_Angeles",
    username: "Jane Smith",
  },
};

const Cookie = {
  get: vi.fn((name) => cookies.current[name]),
  // The browser keeps every cookie value as a string, and js-cookie reads
  // it back that way: set("community_id", 7) reads back as "7".
  set: vi.fn((name, value) => {
    cookies.current[name] = String(value);
  }),
  remove: vi.fn((name) => {
    delete cookies.current[name];
  }),
};

export default Cookie;
