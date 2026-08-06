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
// `get` reads the fixture at call time, so changes apply immediately.
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
  set: vi.fn(),
  remove: vi.fn(),
};

export default Cookie;
