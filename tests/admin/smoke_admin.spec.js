// The admin check of the post-deploy smoke test (tests/smoke/checks.js),
// run against the admin suite's real Rails server with the admin
// tests/admin/seed.rb creates. On production bin/smoke runs the same
// function as the owner's admin account.
const { test, expect } = require("../helpers/test");
const { checkAdmin, ADMIN_REFUSED } = require("../smoke/checks");

test.describe("the smoke test's admin check", () => {
  test("signs in, opens the dashboard and the reconciliations, and changes nothing it can avoid", async ({
    page,
    baseURL,
  }) => {
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
    // "Remember me" is on by default. Left on, the login would write a
    // remember token to the admin's row; the smoke test unticks it.
    const cookies = await page.context().cookies();
    expect(cookies.map((c) => c.name)).not.toContain(
      "remember_admin_user_token",
    );
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
