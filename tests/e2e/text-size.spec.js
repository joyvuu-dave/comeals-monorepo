// Large text (challenge 32). Zooming a page to 200% halves its width in
// CSS pixels: an iPad held upright (820 wide) then lays the page out at
// 410. Nothing may be drawn on top of something else at that width.
const { test, expect } = require("../helpers/test");
const { FROZEN_NOW, setupAuthenticatedPage } = require("../helpers/setup");

const CALENDAR = "/calendar/all/2026-01-15/";

test.describe("At 200% zoom on an upright iPad", () => {
  test.use({ viewport: { width: 410, height: 590 } });

  test("the calendar's header holds its links", async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
    await page.clock.setFixedTime(FROZEN_NOW);
    await page.goto(CALENDAR);
    const header = page.locator("header.header");
    const logout = header.getByRole("button", { name: /^logout / });
    await expect(logout).toBeVisible();
    const headerBox = await header.boundingBox();
    for (const button of await header.getByRole("button").all()) {
      const box = await button.boundingBox();
      expect(
        box.y + box.height,
        `"${await button.textContent()}" ends below the header`,
      ).toBeLessThanOrEqual(headerBox.y + headerBox.height);
    }
  });
});
