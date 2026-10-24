import { describe, it, expect } from "vitest";
import {
  adminBaseFor,
  redact,
  signInResident,
  RESIDENT_REFUSED,
} from "../smoke/checks.js";

// The parts of the post-deploy smoke test (tests/smoke/smoke.js) that
// need no browser. The admin check itself runs against a real Rails
// server in tests/admin/smoke_admin.spec.js.

describe("adminBaseFor", () => {
  // config/routes.rb serves admin on the "admin" subdomain of the host.
  it("puts admin. in front of the site's host", () => {
    expect(adminBaseFor("https://comeals.com")).toBe(
      "https://admin.comeals.com",
    );
    expect(adminBaseFor("https://www.comeals.com/")).toBe(
      "https://admin.comeals.com",
    );
    expect(adminBaseFor("http://lvh.me:3000")).toBe("http://admin.lvh.me:3000");
  });

  // localhost has no subdomains; development serves admin at
  // admin.lvh.me, which points at this machine.
  it("uses admin.lvh.me for localhost", () => {
    expect(adminBaseFor("http://localhost:3000")).toBe(
      "http://admin.lvh.me:3000",
    );
    expect(adminBaseFor("http://127.0.0.1:3000")).toBe(
      "http://admin.lvh.me:3000",
    );
  });

  // Heroku answers only the app's own herokuapp.com name, so staging
  // has no admin host.
  it("has no admin host for a herokuapp.com address", () => {
    expect(
      adminBaseFor("https://comeals-staging-ad51b8a1eb64.herokuapp.com"),
    ).toBe(null);
  });
});

describe("redact", () => {
  it("hides every secret it is given, every time it appears", () => {
    expect(
      redact("typed s3cret and s3cret, then other-one", [
        "s3cret",
        "other-one",
      ]),
    ).toBe("typed [hidden] and [hidden], then [hidden]");
  });

  it("ignores secrets that are not set", () => {
    expect(redact("nothing to hide", [undefined, ""])).toBe("nothing to hide");
  });

  it("turns anything into text", () => {
    expect(redact(new Error("boom s3cret"), ["s3cret"])).toBe(
      "Error: boom [hidden]",
    );
  });
});

// A page with just what signInResident uses. The token answer has the
// status the test gives it.
function fakePage(status) {
  const filled = {};
  let clicked = false;
  return {
    filled,
    clicked: () => clicked,
    fill: async (selector, value) => {
      filled[selector] = value;
    },
    getByRole: () => ({
      click: async () => {
        clicked = true;
      },
    }),
    waitForResponse: async (match) => {
      const response = {
        url: () => "https://comeals.com/api/v1/residents/token",
        request: () => ({ method: () => "POST" }),
        status: () => status,
      };
      if (!match(response)) throw new Error("the wrong request matched");
      if (
        match({
          url: () => "https://comeals.com/api/v1/version",
          request: () => ({ method: () => "GET" }),
        })
      ) {
        throw new Error("another request matched");
      }
      return response;
    },
  };
}

describe("signInResident", () => {
  it("fills the form, submits it, and goes on when the login works", async () => {
    const page = fakePage(200);

    await signInResident(page, "me@example.com", "pw");

    expect(page.filled).toEqual({
      'input[aria-label="email"]': "me@example.com",
      'input[aria-label="password"]': "pw",
    });
    expect(page.clicked()).toBe(true);
  });

  // The API answers 400 for an unknown email and for a wrong password
  // (Api::V1::ResidentsController#token).
  it("says the login was refused, and what to update, on a 400", async () => {
    await expect(signInResident(fakePage(400), "a", "b")).rejects.toThrow(
      RESIDENT_REFUSED,
    );
    expect(RESIDENT_REFUSED).toBe(
      "smoke login refused for the resident account — update " +
        "SMOKE_EMAIL/SMOKE_PASSWORD (or RESIDENT_*) in .env and the GitHub secrets",
    );
  });

  it("names any other answer", async () => {
    await expect(signInResident(fakePage(429), "a", "b")).rejects.toThrow(
      "the resident login answered 429",
    );
  });
});
