// Large text (challenge 32). Zooming a page to 200% halves its width in
// CSS pixels, so each screen is checked at half the width of the
// devices it is used on: an iPad on its side (1180 wide) and upright
// (820), and a laptop (1280). At each one, no control may be drawn on
// top of another, and no text may be cut off.
const { test, expect } = require("../helpers/test");
const {
  FROZEN_NOW,
  setupAuthenticatedPage,
  stubPusher,
  disableIdleTimer,
  mockApi,
} = require("../helpers/setup");
const { layoutProblems } = require("../helpers/accessibility");

const mealFixture = require("../fixtures/meal.json");

const CALENDAR = "/calendar/all/2026-01-15/";

const WIDTHS = [
  { device: "an iPad on its side", width: 590, height: 410 },
  { device: "an upright iPad", width: 410, height: 590 },
  { device: "a laptop", width: 640, height: 360 },
  // WCAG 1.4.10: a page must fit 320 pixels wide (a laptop at 400%).
  { device: "a laptop at 400%", width: 320, height: 180 },
];

// `scope` limits the check to a dialog: the page behind it is hidden
// from the person and cannot be tapped.
const SCREENS = [
  {
    name: "login",
    url: "/",
    signedIn: false,
    ready: 'input[aria-label="email"]',
  },
  { name: "calendar", url: CALENDAR, ready: ".rbc-event" },
  { name: "meal", url: "/meals/42/edit/", ready: "table" },
  {
    name: "closed meal",
    url: "/meals/42/edit/",
    ready: "input[aria-label='Set Extras to 0']",
    api: {
      mealData: {
        ...mealFixture,
        closed: true,
        closed_at: "2026-01-15T08:00:00Z",
      },
    },
  },
  {
    name: "new event",
    url: `${CALENDAR}events/new/`,
    ready: "form",
    scope: "[role='dialog']",
  },
  {
    name: "new Common House booking",
    url: `${CALENDAR}common-house-reservations/new/`,
    ready: "form",
    scope: "[role='dialog']",
  },
  {
    name: "new guest room booking",
    url: `${CALENDAR}guest-room-reservations/new/`,
    ready: "form",
    scope: "[role='dialog']",
  },
  {
    name: "profile",
    url: `${CALENDAR}profile/edit/`,
    ready: "form",
    scope: "[role='dialog']",
  },
  {
    name: "event edit",
    url: `${CALENDAR}events/edit/70/`,
    ready: "form",
    scope: "[role='dialog']",
  },
  {
    name: "rotation",
    url: `${CALENDAR}rotations/show/10/`,
    ready: "[data-populated='true']",
    scope: "[role='dialog']",
  },
];

for (const { device, width, height } of WIDTHS) {
  test.describe(`On ${device} (${width}px)`, () => {
    test.use({ viewport: { width, height } });

    for (const screen of SCREENS) {
      test(screen.name, async ({ page, context }) => {
        if (screen.signedIn === false) {
          await stubPusher(page);
          await disableIdleTimer(page);
          await mockApi(page);
        } else {
          await setupAuthenticatedPage(page, context, screen.api || {});
        }
        await page.clock.setFixedTime(FROZEN_NOW);
        await page.goto(screen.url);
        await expect(page.locator(screen.ready).first()).toBeVisible({
          timeout: 10000,
        });
        await page.waitForLoadState("networkidle");
        expect(
          await page.evaluate(
            () => window.document.documentElement.scrollWidth,
          ),
          "the page is wider than the screen",
        ).toBeLessThanOrEqual(width);
        expect(await layoutProblems(page, screen.scope)).toEqual([]);
        // A form's main button must be on screen without scrolling,
        // however short the window.
        if (screen.scope) {
          const submit = page.locator(`${screen.scope} button[type=submit]`);
          if (await submit.count()) {
            await expect(submit).toBeInViewport({ ratio: 1 });
          }
        }
      });
    }

    test("the calendar's header holds its links", async ({ page, context }) => {
      await setupAuthenticatedPage(page, context);
      await page.clock.setFixedTime(FROZEN_NOW);
      await page.goto(CALENDAR);
      const header = page.locator("header.header");
      await expect(
        header.getByRole("button", { name: /^logout / }),
      ).toBeVisible();
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
}
