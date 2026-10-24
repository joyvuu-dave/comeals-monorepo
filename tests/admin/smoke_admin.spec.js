// The admin check of the post-deploy smoke test (tests/smoke/checks.js),
// run against the admin suite's real Rails server with the admin
// tests/admin/seed.rb creates. On production bin/smoke runs the same
// function as the owner's admin account.
const { test, expect } = require("../helpers/test");
const { checkAdmin, ADMIN_REFUSED } = require("../smoke/checks");

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

  test("fails with what to update when the login is refused", async ({
    page,
    baseURL,
  }) => {
    await expect(
      checkAdmin(page, baseURL, "admin@example.com", "wrong"),
    ).rejects.toThrow(ADMIN_REFUSED);
    expect(ADMIN_REFUSED).toBe(
      "smoke login refused for the admin account — update " +
        "SMOKE_ADMIN_* (or ADMIN_*) in .env and the GitHub secrets",
    );
  });
});
