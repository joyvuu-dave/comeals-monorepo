// One golden image per admin page, against the rows tests/admin/seed.rb
// writes. spec/admin/visual_goldens_spec.rb derives the list of pages
// from the routes and fails when a page here is missing, so adding an
// admin page means adding its line below and recording its goldens.
//
// Goldens are recorded per platform: -admin-darwin.png by a plain run on
// a Mac, -admin-linux.png by bin/update-linux-snapshots, which runs this
// suite in the Playwright container against Rails on the host.
const { test, expect } = require("../helpers/test");

// tests/admin/seed.rb sets the raw token behind this digest.
const ADMIN_RESET_TOKEN = "admin-e2e-reset-token";

// [golden name, path]. The name is <resource>-<action>, the same words
// the route spec builds from the routes. Ids point at the seed row that
// shows the most: meal 3 is settled (line items), ledger check 2 found a
// difference, resident 1 has a statement.
const SIGNED_OUT_PAGES = [
  ["login", "/login"],
  ["password-new", "/password/new"],
  ["password-edit", `/password/edit?reset_password_token=${ADMIN_RESET_TOKEN}`],
];

const SIGNED_IN_PAGES = [
  ["dashboard-index", "/dashboard"],
  ["admin_users-index", "/admin_users"],
  ["admin_users-show", "/admin_users/1"],
  ["admin_users-new", "/admin_users/new"],
  ["admin_users-edit", "/admin_users/1/edit"],
  ["bills-index", "/bills"],
  ["bills-show", "/bills/1"],
  ["bills-new", "/bills/new"],
  ["bills-edit", "/bills/1/edit"],
  ["common_house_reservations-index", "/common_house_reservations"],
  ["common_house_reservations-show", "/common_house_reservations/1"],
  ["common_house_reservations-new", "/common_house_reservations/new"],
  ["common_house_reservations-edit", "/common_house_reservations/1/edit"],
  ["communities-show", "/communities/1"],
  ["communities-edit", "/communities/1/edit"],
  ["events-index", "/events"],
  ["events-show", "/events/1"],
  ["events-new", "/events/new"],
  ["events-edit", "/events/1/edit"],
  ["guest_room_reservations-index", "/guest_room_reservations"],
  ["guest_room_reservations-show", "/guest_room_reservations/1"],
  ["guest_room_reservations-new", "/guest_room_reservations/new"],
  ["guest_room_reservations-edit", "/guest_room_reservations/1/edit"],
  ["ledger_check_runs-index", "/ledger_check_runs"],
  ["ledger_check_runs-show", "/ledger_check_runs/2"],
  ["meals-index", "/meals"],
  ["meals-show", "/meals/3"],
  ["meals-new", "/meals/new"],
  ["meals-edit", "/meals/1/edit"],
  ["reconciliations-index", "/reconciliations"],
  ["reconciliations-show", "/reconciliations/1"],
  ["reconciliations-new", "/reconciliations/new"],
  ["residents-index", "/residents"],
  ["residents-show", "/residents/1"],
  ["residents-new", "/residents/new"],
  ["residents-edit", "/residents/1/edit"],
  ["rotations-index", "/rotations"],
  ["rotations-show", "/rotations/1"],
  ["units-index", "/units"],
  ["units-show", "/units/1"],
  ["units-new", "/units/new"],
  ["units-edit", "/units/1/edit"],
];

async function login(page) {
  await page.goto("/login");
  await page.fill("#admin_user_email", "admin@example.com");
  await page.fill("#admin_user_password", "password");
  await page.click('input[type="submit"]');
  await expect(page.locator("#header")).toContainText("admin@example.com");
}

async function photograph(page, name, path) {
  await page.goto(path);
  await page.waitForLoadState("networkidle");
  // A page that redirected (a refused action, a lost session) is not the
  // page this line names; say so instead of photographing the wrong one.
  expect(new URL(page.url()).pathname + new URL(page.url()).search).toBe(path);
  await expect(page).toHaveScreenshot(`${name}.png`, {
    fullPage: true,
    // Devise updates these two on every sign-in, and each test signs in.
    mask: [
      page.locator(".col-current_sign_in_at"),
      page.locator(".col-sign_in_count"),
      page.locator(".row-current_sign_in_at td"),
      page.locator(".row-sign_in_count td"),
    ],
  });
}

test.describe("Admin visual baselines", () => {
  for (const [name, path] of SIGNED_OUT_PAGES) {
    test(name, async ({ page }) => {
      await photograph(page, name, path);
    });
  }

  for (const [name, path] of SIGNED_IN_PAGES) {
    test(name, async ({ page }) => {
      await login(page);
      await photograph(page, name, path);
    });
  }
});
