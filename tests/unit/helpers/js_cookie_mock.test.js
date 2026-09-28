import { describe, it, expect, vi } from "vitest";

// The shared js-cookie mock (tests/unit/mocks/js_cookie.js) and the reset
// in render_setup.js. Store and component tests check what the app reads
// after it writes a cookie, so the mock must act like a cookie jar, and
// a write in one test must not reach the next.

vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));
import Cookie from "js-cookie";
import { cookies } from "../mocks/js_cookie.js";

// A file-level fixture, as a component test would set one. The reset
// must put back this one, not the default.
cookies.current = { ...cookies.current, username: "File Person" };

describe("the shared js-cookie mock", () => {
  it("reads back what set writes, as a string, like the browser", () => {
    Cookie.set("community_id", 7, { expires: 7300 });

    expect(Cookie.get("community_id")).toBe("7");
  });

  it("reads nothing back after remove", () => {
    Cookie.remove("token", { path: "/" });

    expect(Cookie.get("token")).toBeUndefined();
  });

  // The next two run in this order on purpose (vitest does not shuffle):
  // the first changes the jar, the second checks the change is gone.
  describe("between tests", () => {
    it("a test writes, removes and replaces a function", () => {
      Cookie.set("timezone", "America/New_York");
      Cookie.remove("token");
      delete cookies.current.community_id;
      Cookie.get.mockImplementation(() => "replaced");

      expect(Cookie.get("anything")).toBe("replaced");
    });

    it("the next test sees the file's own cookies again", () => {
      expect(Cookie.get("timezone")).toBe("America/Los_Angeles");
      expect(Cookie.get("token")).toBe("test-token");
      expect(Cookie.get("community_id")).toBe("test-community-id");
      expect(Cookie.get("username")).toBe("File Person");
    });
  });
});
