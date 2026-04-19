const path = require("path");
const { test, expect } = require("@playwright/test");
const { setupAuthenticatedPage } = require("../helpers/setup");

/**
 * Regenerates the PWA manifest screenshots in public/.
 *
 * Not a correctness test -- invoked explicitly via `npm run pwa:screenshots`
 * and excluded from the default e2e run in playwright.config.js.
 *
 * Produces:
 *   public/screenshot-desktop.png  (1280x800, form_factor: wide)
 *   public/screenshot-mobile.png   (414x896,  form_factor: narrow)
 */

const PUBLIC_DIR = path.resolve(__dirname, "../../public");
const TARGET_URL = "/calendar/all/2026-01-15/";
const FROZEN_TIME = new Date("2026-01-15T12:00:00");

async function captureCalendar(page, context, { width, height, outputFile }) {
  await page.setViewportSize({ width, height });
  await setupAuthenticatedPage(page, context);
  await page.clock.setFixedTime(FROZEN_TIME);

  await page.goto(TARGET_URL);
  await page.waitForLoadState("networkidle");
  await expect(page.locator(".rbc-calendar")).toBeVisible({ timeout: 10000 });
  // Let event layout / animations settle
  await page.waitForTimeout(1000);

  await page.screenshot({
    path: path.join(PUBLIC_DIR, outputFile),
    fullPage: false,
  });
}

test.describe("PWA manifest screenshots", () => {
  test("desktop (wide)", async ({ page, context }) => {
    await captureCalendar(page, context, {
      width: 1280,
      height: 800,
      outputFile: "screenshot-desktop.png",
    });
  });

  test("mobile (narrow)", async ({ page, context }) => {
    await captureCalendar(page, context, {
      width: 414,
      height: 896,
      outputFile: "screenshot-mobile.png",
    });
  });
});
