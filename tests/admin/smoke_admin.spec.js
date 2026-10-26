// The admin check of the post-deploy smoke test (tests/smoke/checks.js),
// run against the admin suite's real Rails server with the admin
// tests/admin/seed.rb creates. On production bin/smoke runs the same
// function as the owner's admin account.
const { test, expect } = require("../helpers/test");
const { checkAdmin, ADMIN_REFUSED, LoginRefused } = require("../smoke/checks");

test.describe("the smoke test's admin check", () => {
  test("signs in, opens the dashboard and the reconciliations, and does not ask to be remembered", async ({
    page,
    baseURL,
  }) => {
    const logins = [];
    page.on("request", (request) => {
      if (
        request.method() === "POST" &&
        new URL(request.url()).pathname === "/login"
      ) {
        logins.push(request.postData());
      }
    });

    const passed = await checkAdmin(
      page,
      baseURL,
      "admin@example.com",
      "password",
    );

    expect(passed).toEqual([
      "admin login works",
      "admin dashboard renders",
      "admin reconciliations page renders",
    ]);
    // One login. "Remember me" is ticked by default (active_admin.js);
    // sent ticked, Devise would write a remember time on the admin's row.
    // A ticked box sends remember_me=1 after the hidden 0.
    expect(logins).toHaveLength(1);
    expect(logins[0]).toContain("admin_user%5Bremember_me%5D=0");
    expect(logins[0]).not.toContain("admin_user%5Bremember_me%5D=1");
  });

  // A refused login is its own kind of failure (LoginRefused): bin/smoke
  // then ends with its own exit code, and the callers say to check the
  // credentials, not that the site is broken. This pins Devise's real
  // words for a wrong password, which checkAdmin reads.
  test("fails with what to check when the login is refused", async ({
    page,
    baseURL,
  }) => {
    const error = await checkAdmin(
      page,
      baseURL,
      "admin@example.com",
      "wrong",
    ).catch((e) => e);

    expect(error).toBeInstanceOf(LoginRefused);
    expect(error.message).toBe(ADMIN_REFUSED);
  });

  test("fails with what to check when no admin has the email", async ({
    page,
    baseURL,
  }) => {
    const error = await checkAdmin(
      page,
      baseURL,
      "nobody@example.com",
      "password",
    ).catch((e) => e);

    expect(error).toBeInstanceOf(LoginRefused);
    expect(error.message).toBe(ADMIN_REFUSED);
  });
});
