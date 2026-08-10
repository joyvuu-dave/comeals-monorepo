// ActiveAdmin smoke tests, run against a real Rails server on port 3038
// (tests/admin/server.sh) with deterministic data (tests/admin/seed.rb).
// These pin the pieces custom CSS/JS and admin config are responsible
// for: the login banner, server-rendered meal dates, the datepicker,
// and the singular Community title.
const { test, expect } = require("../helpers/test");

// Seeded by tests/admin/seed.rb: meal 1 on 2027-02-04, bill 1 on meal 1.
const MEAL_DATE_TEXT = "Thu, Feb 4 2027";

async function login(page) {
  await page.goto("/login");
  await page.fill("#admin_user_email", "admin@example.com");
  await page.fill("#admin_user_password", "password");
  await page.click('input[type="submit"]');
  // The signed-in email in the header proves the session, regardless of
  // what the dashboard page is titled.
  await expect(page.locator("#header")).toContainText("admin@example.com");
}

test.describe("Admin", () => {
  test("login page shows the banner and a resident-login link", async ({
    page,
  }) => {
    await page.goto("/login");

    const banner = page.locator(".admin-login-banner");
    await expect(banner.locator("h3")).toHaveText("Admin Login");
    // The link strips the admin subdomain from the current host.
    await expect(banner.locator("a")).toHaveAttribute(
      "href",
      "http://lvh.me:3038",
    );

    // Remember me defaults to checked (active_admin.js).
    await expect(page.locator("#admin_user_remember_me")).toBeChecked();
  });

  test("rejects a wrong password", async ({ page }) => {
    await page.goto("/login");
    await page.fill("#admin_user_email", "admin@example.com");
    await page.fill("#admin_user_password", "wrong");
    await page.click('input[type="submit"]');

    await expect(page.getByText("Invalid Email or password")).toBeVisible();
  });

  test("logs in to the dashboard", async ({ page }) => {
    await login(page);
  });

  test("meal dates are readable, with the right weekday", async ({ page }) => {
    await login(page);
    await page.goto("/meals");

    // Server-rendered via date.formats.admin (config/locales/en.yml).
    // 2027-02-04 really is a Thursday — this catches any return of the
    // old client-side reformatting, which shifted dates by timezone.
    await expect(page.locator("td.col-date").first()).toHaveText(
      MEAL_DATE_TEXT,
    );
  });

  test("bill form names the meal by readable date", async ({ page }) => {
    await login(page);
    await page.goto("/bills/1/edit");

    await expect(page.locator("#bill_meal_id option:checked")).toHaveText(
      MEAL_DATE_TEXT,
    );
  });

  test("meal date field opens a datepicker on the right month", async ({
    page,
  }) => {
    await login(page);
    await page.goto("/meals/1/edit");

    await expect(page.locator("#meal_date")).toHaveValue("2027-02-04");
    await page.click("#meal_date");

    const datepicker = page.locator(".ui-datepicker:visible");
    await expect(datepicker).toBeVisible();
    await expect(datepicker.locator(".ui-datepicker-title")).toHaveText(
      "February 2027",
    );
  });

  test("community page title is singular", async ({ page }) => {
    await login(page);
    await page.goto("/communities");

    await expect(page.locator("#page_title")).toHaveText("Community");
  });
});
