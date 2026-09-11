// Sign in as the superuser tests/admin/seed.rb creates. Every admin spec
// file starts here; the signed-in email in the header proves the session,
// whatever the dashboard page is titled.
const { expect } = require("../helpers/test");

async function login(page) {
  await page.goto("/login");
  await page.fill("#admin_user_email", "admin@example.com");
  await page.fill("#admin_user_password", "password");
  await page.click('input[type="submit"]');
  await expect(page.locator("#header")).toContainText("admin@example.com");
}

module.exports = { login };
