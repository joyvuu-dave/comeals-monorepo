import { describe, it, expect } from "vitest";
import {
  adminBaseFor,
  pageKeysOlderRelease,
  pageKeysProblem,
  redact,
  signInResident,
  checkAdmin,
  LoginRefused,
  unlessRefused,
  countedProblems,
  refusedReport,
  EXIT,
  ADMIN_REFUSED,
  RESIDENT_WRONG_PASSWORD,
  RESIDENT_UNKNOWN_EMAIL,
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
// status and the JSON body the test gives it.
function fakePage(status, body = {}) {
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
        json: async () => body,
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

  // The API answers 400 with "Incorrect password" for a wrong password
  // and "No resident with email <email>" for an unknown email
  // (Api::V1::ResidentsController#token). Both are a refused login:
  // the site works, and the smoke credentials are wrong.
  it("says the login was refused, why, and what to check, for a wrong password", async () => {
    const attempt = signInResident(
      fakePage(400, { message: "Incorrect password" }),
      "a",
      "b",
    );

    await expect(attempt).rejects.toThrow(LoginRefused);
    await expect(attempt).rejects.toThrow(RESIDENT_WRONG_PASSWORD);
    expect(RESIDENT_WRONG_PASSWORD).toBe(
      "the site refused the resident login (it says the password is " +
        "wrong) — check SMOKE_EMAIL/SMOKE_PASSWORD (or RESIDENT_*) in .env " +
        "and the GitHub secrets",
    );
  });

  // The answer names the email. The message does not, so the email never
  // reaches a log.
  it("says the login was refused for an unknown email, without the email", async () => {
    const attempt = signInResident(
      fakePage(400, { message: "No resident with email who@example.com" }),
      "who@example.com",
      "b",
    );

    await expect(attempt).rejects.toThrow(LoginRefused);
    await expect(attempt).rejects.toThrow(RESIDENT_UNKNOWN_EMAIL);
    expect(RESIDENT_UNKNOWN_EMAIL).toBe(
      "the site refused the resident login (it has no resident with " +
        "that email) — check SMOKE_EMAIL/SMOKE_PASSWORD (or RESIDENT_*) " +
        "in .env and the GitHub secrets",
    );
  });

  // Rails also answers 400 for a request it cannot read. That is a broken
  // site, not a refused login.
  it("treats a 400 with any other message as a broken site", async () => {
    const attempt = signInResident(
      fakePage(400, { message: "Email required." }),
      "a",
      "b",
    );

    await expect(attempt).rejects.toThrow("the resident login answered 400");
    await expect(attempt).rejects.not.toThrow(LoginRefused);
  });

  it("treats a 400 whose body is not JSON as a broken site", async () => {
    const page = fakePage(400);
    const realWait = page.waitForResponse;
    page.waitForResponse = async (match) => {
      const response = await realWait(match);
      return {
        ...response,
        json: async () => {
          throw new SyntaxError("Unexpected token <");
        },
      };
    };

    await expect(signInResident(page, "a", "b")).rejects.toThrow(
      "the resident login answered 400",
    );
  });

  it("names any other answer", async () => {
    await expect(signInResident(fakePage(429), "a", "b")).rejects.toThrow(
      "the resident login answered 429",
    );
  });
});

// A page with just what checkAdmin uses, on the admin login page after the
// form was sent. With alert, the login page came back with that alert;
// without it, the dashboard opened.
function fakeAdminPage(alert) {
  const onLoginPage = alert !== undefined;
  return {
    goto: async () => ({ status: () => 200 }),
    fill: async () => {},
    uncheck: async () => {},
    click: async () => {},
    locator: (selector) => ({
      first: () => ({
        waitFor: async () => {},
        textContent: async () => (selector === ".flash_alert" ? alert : ""),
      }),
      count: async () =>
        selector === "#admin_user_password" && onLoginPage ? 1 : 0,
      textContent: async () => "",
    }),
  };
}

describe("checkAdmin", () => {
  // Devise's words for a wrong email or a wrong password
  // (config/locales/devise.en.yml, invalid and not_found_in_database).
  it("says the login was refused when the login page comes back saying the email or password is wrong", async () => {
    const attempt = checkAdmin(
      fakeAdminPage("  Invalid email or password.\n"),
      "https://admin.comeals.com",
      "a",
      "b",
    );

    await expect(attempt).rejects.toThrow(LoginRefused);
    await expect(attempt).rejects.toThrow(ADMIN_REFUSED);
    expect(ADMIN_REFUSED).toBe(
      "the site refused the admin login (it says the email or the " +
        "password is wrong) — check SMOKE_ADMIN_* (or ADMIN_*) in .env and " +
        "the GitHub secrets",
    );
  });

  // The sign-in worked but the next page did not keep it (a broken
  // session cookie, say): Devise sends the browser back to the login page
  // with another alert. Every admin is locked out, so the site is broken.
  it("treats the login page coming back with any other alert as a broken site", async () => {
    const attempt = checkAdmin(
      fakeAdminPage("You need to sign in before continuing."),
      "https://admin.comeals.com",
      "a",
      "b",
    );

    await expect(attempt).rejects.toThrow(
      'the admin login page came back with "You need to sign in before ' +
        'continuing." — the site did not keep the sign-in',
    );
    await expect(attempt).rejects.not.toThrow(LoginRefused);
  });
});

// bin/smoke's exit codes, which bin/deploy, the Deploy and Rollback
// workflows and bin/staging-rehearsal read (the top of bin/smoke).
describe("EXIT", () => {
  it("has one code for a pass, one for a broken site, one for a refused login", () => {
    expect(EXIT).toEqual({ passed: 0, broken: 1, loginRefused: 2 });
  });
});

describe("unlessRefused", () => {
  it("returns what the checks return when the login works", async () => {
    const refused = [];

    expect(await unlessRefused(refused, async () => ["a", "b"])).toEqual([
      "a",
      "b",
    ]);
    expect(refused).toEqual([]);
  });

  // The rest of the smoke test still runs: a refused resident login must
  // not hide a broken admin site.
  it("notes a refused login, and returns no passed checks", async () => {
    const refused = [];

    const passed = await unlessRefused(refused, async () => {
      throw new LoginRefused("refused, check X");
    });

    expect(passed).toEqual([]);
    expect(refused).toEqual(["refused, check X"]);
  });

  it("lets any other failure through", async () => {
    await expect(
      unlessRefused([], async () => {
        throw new Error("the calendar did not render");
      }),
    ).rejects.toThrow("the calendar did not render");
  });
});

describe("countedProblems", () => {
  const base = "https://comeals.com";
  const refusedAnswer = {
    text: "console error: Failed to load resource: the server responded with a status of 400 (Bad Request)",
    url: `${base}/api/v1/residents/token`,
  };
  const other400 = {
    text: refusedAnswer.text,
    url: `${base}/api/v1/browser-reports`,
  };
  const appError = { text: "page error: boom", url: "" };

  // The browser logs the refused answer itself, with the token address
  // as the line's location. That line is the refusal, not a second
  // problem.
  it("drops the browser's line for the refused resident login", () => {
    expect(countedProblems([refusedAnswer, other400, appError], true)).toEqual([
      other400.text,
      appError.text,
    ]);
  });

  it("keeps that line when the resident login was not refused", () => {
    expect(countedProblems([refusedAnswer], false)).toEqual([
      refusedAnswer.text,
    ]);
  });
});

describe("refusedReport", () => {
  it("says which logins were refused, that this is not a pass, and what to check", () => {
    expect(
      refusedReport("https://comeals.com", [
        "resident refused",
        "admin refused",
      ]),
    ).toEqual([
      "SMOKE LOGIN REFUSED against https://comeals.com:",
      "  resident refused",
      "  admin refused",
      "The site answered, and every check that could run passed, but it " +
        "refused a login, so the checks behind that login did not run. " +
        "This is not a pass. Check the SMOKE_* credentials. If they are " +
        "right, sign in by hand: if that fails too, the site is broken.",
    ]);
  });
});

describe("pageKeysProblem", () => {
  const tags = (pusherKey) => [
    { name: "comeals-pusher-key", content: pusherKey },
    { name: "comeals-pusher-cluster", content: "us2" },
    { name: "comeals-bugsnag-api-key", content: "" },
  ];

  it("passes the real site's page with a Pusher key", () => {
    expect(pageKeysProblem("https://comeals.com", tags("key"))).toBeNull();
  });

  // What production would send if it ran a build made on staging (#257).
  it("fails the real site's page with no Pusher key", () => {
    expect(pageKeysProblem("https://comeals.com", tags(""))).toBe(
      "the page has no Pusher key, so screens will not update by themselves",
    );
  });

  it("passes staging's page and a local page with no Pusher key", () => {
    expect(
      pageKeysProblem("https://comeals-staging.herokuapp.com", tags("")),
    ).toBeNull();
    expect(pageKeysProblem("http://localhost:3000", tags(""))).toBeNull();
    expect(pageKeysProblem("http://127.0.0.1:3000", tags(""))).toBeNull();
  });

  it("fails a page with a tag missing or twice, on any site", () => {
    expect(pageKeysProblem("http://localhost:3000", tags("key").slice(1))).toBe(
      "the page has 0 comeals-pusher-key tag(s), not 1",
    );
    expect(
      pageKeysProblem("https://comeals.com", [
        ...tags("key"),
        { name: "comeals-bugsnag-api-key", content: "" },
      ]),
    ).toBe("the page has 2 comeals-bugsnag-api-key tag(s), not 1");
  });
});

// Production before this change, and after a rollback to such a release:
// the keys are built into the JavaScript and the page has no tags.
describe("a page from before #257", () => {
  it("is not a problem, and is named as an older release", () => {
    expect(pageKeysProblem("https://comeals.com", [])).toBeNull();
    expect(pageKeysOlderRelease([])).toBe(true);
    expect(
      pageKeysOlderRelease([{ name: "comeals-pusher-key", content: "k" }]),
    ).toBe(false);
  });
});
