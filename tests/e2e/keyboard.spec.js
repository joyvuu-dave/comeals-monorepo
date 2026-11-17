// Keyboard use (challenge 32). Everything a mouse can do on these
// screens must work with Tab, Enter, Space and Escape alone, and the
// control that has the focus must show a ring.
const { test, expect } = require("../helpers/test");
const {
  FROZEN_NOW,
  setupAuthenticatedPage,
  stubPusher,
  disableIdleTimer,
  mockApi,
} = require("../helpers/setup");
const {
  nextKey,
  stopTransitions,
  walkWithTab,
  missedByTab,
} = require("../helpers/accessibility");

const mealFixture = require("../fixtures/meal.json");

const CALENDAR = "/calendar/all/2026-01-15/";

async function open(page, context, url, { signedIn = true, api = {} } = {}) {
  if (signedIn) {
    await setupAuthenticatedPage(page, context, api);
  } else {
    await stubPusher(page);
    await disableIdleTimer(page);
    await mockApi(page);
  }
  await page.clock.setFixedTime(FROZEN_NOW);
  await page.goto(url);
  await page.waitForLoadState("networkidle");
}

// Press Tab until `target` has the focus. Fails if the focus comes back
// to where it started first, which means Tab cannot reach the target.
async function tabTo(page, target) {
  await expect(target).toBeVisible();
  const handle = await target.elementHandle();
  const key = nextKey(page);
  for (let i = 0; i < 250; i++) {
    await page.keyboard.press(key);
    const there = await handle.evaluate(
      (el) => el === window.document.activeElement,
    );
    if (there) return;
  }
  throw new Error("Tab never reached the element");
}

test.describe("Keyboard only", () => {
  test("signs a resident up for dinner", async ({ page, context }) => {
    await open(page, context, "/meals/42/edit/");
    const bob = page.getByRole("button", {
      name: "B - Bob Johnson",
      exact: true,
    });
    await expect(bob).toHaveAttribute("aria-pressed", "false");
    await tabTo(page, bob);
    await page.keyboard.press("Enter");
    await expect(bob).toHaveAttribute("aria-pressed", "true");
    await expect(
      page.getByRole("cell", { name: "B - Bob Johnson", exact: true }),
    ).toHaveClass(/background-green/);
  });

  test("adds a guest, and the focus goes back to + Guest", async ({
    page,
    context,
  }) => {
    await open(page, context, "/meals/42/edit/");
    const add = page.getByRole("button", {
      name: "Add Guest of B - Bob Johnson",
    });
    await tabTo(page, add);
    await page.keyboard.press("Enter");
    await expect(add).toHaveAttribute("aria-expanded", "true");
    await page.keyboard.press(nextKey(page));
    await page.keyboard.press(nextKey(page));
    const veg = page.getByRole("button", {
      name: "Add a vegetarian guest of B - Bob Johnson",
    });
    await expect(veg).toBeFocused();
    await page.keyboard.press("Enter");
    const bobRow = page
      .getByRole("cell", { name: "B - Bob Johnson", exact: true })
      .locator("xpath=ancestor::tr");
    await expect(bobRow.locator('.badge img[alt="carrot-icon"]')).toHaveCount(
      1,
    );
    await expect(add).toBeFocused();
  });

  test("Escape closes the guest menu and keeps the focus on + Guest", async ({
    page,
    context,
  }) => {
    await open(page, context, "/meals/42/edit/");
    const add = page.getByRole("button", {
      name: "Add Guest of B - Bob Johnson",
    });
    await tabTo(page, add);
    await page.keyboard.press("Enter");
    await page.keyboard.press(nextKey(page));
    await page.keyboard.press("Escape");
    await expect(add).toHaveAttribute("aria-expanded", "false");
    await expect(add).toBeFocused();
  });

  test("Tab out of the guest menu closes it", async ({ page, context }) => {
    await open(page, context, "/meals/42/edit/");
    const add = page.getByRole("button", {
      name: "Add Guest of B - Bob Johnson",
    });
    await tabTo(page, add);
    await page.keyboard.press("Enter");
    // + Guest, the two menu items, then the next control.
    await page.keyboard.press(nextKey(page));
    await page.keyboard.press(nextKey(page));
    await page.keyboard.press(nextKey(page));
    await expect(add).toHaveAttribute("aria-expanded", "false");
  });

  test("opens a dinner from the calendar", async ({ page, context }) => {
    await open(page, context, CALENDAR);
    const dinner = page.locator(".rbc-event a[href^='/meals/']").first();
    const href = await dinner.getAttribute("href");
    await tabTo(page, dinner);
    await page.keyboard.press("Enter");
    await expect(page).toHaveURL(new RegExp(`${href}/?$`));
  });

  test("a closed form gives the focus back to the button that opened it", async ({
    page,
    context,
  }) => {
    await open(page, context, CALENDAR);
    const opener = page.getByRole("button", { name: "Event", exact: true });
    await tabTo(page, opener);
    await page.keyboard.press("Enter");
    await expect(page.getByRole("dialog")).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(page.getByRole("dialog")).toBeHidden();
    await expect(opener).toBeFocused();
  });

  test("a closed entry gives the focus back to the entry", async ({
    page,
    context,
  }) => {
    await open(page, context, CALENDAR);
    const entry = page.locator(".rbc-event a[href*='/events/edit/']").first();
    await tabTo(page, entry);
    await page.keyboard.press("Enter");
    await expect(page.getByRole("dialog")).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(page.getByRole("dialog")).toBeHidden();
    await expect(entry).toBeFocused();
  });
});

// Every screen: Tab reaches everything that takes a click, and every
// stop shows the focus ring. `scope` limits the check to a dialog,
// whose focus stays inside it.
const SCREENS = [
  {
    name: "login",
    url: "/",
    signedIn: false,
    ready: 'input[aria-label="email"]',
  },
  {
    name: "password reset",
    url: "/reset-password#token=t",
    signedIn: false,
    ready: "input",
  },
  { name: "calendar", url: CALENDAR, ready: ".rbc-event" },
  { name: "meal", url: "/meals/42/edit/", ready: "table" },
  {
    // A closed dinner shows Extras.
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
    name: "event edit",
    url: `${CALENDAR}events/edit/70/`,
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
    name: "rotation",
    url: `${CALENDAR}rotations/show/10/`,
    ready: "[data-populated='true']",
    scope: "[role='dialog']",
  },
];

test.describe("Tab on every screen", () => {
  for (const screen of SCREENS) {
    test(screen.name, async ({ page, context }) => {
      await open(page, context, screen.url, screen);
      await expect(page.locator(screen.ready).first()).toBeVisible({
        timeout: 10000,
      });
      await stopTransitions(page);
      const stops = await walkWithTab(page);
      expect(stops.length).toBeGreaterThan(0);
      expect(
        stops.filter((stop) => !stop.ring),
        "Tab stops that show no focus ring",
      ).toEqual([]);
      expect(
        await missedByTab(page, screen.scope),
        "elements a mouse can click that Tab never reached",
      ).toEqual([]);
    });
  }
});

// The axe check runs in the visual suite, before each screenshot. A
// screenshot added without it would leave that screen unchecked, so
// the two are counted here.
test("every screenshot in the visual suite is checked by axe", () => {
  const source = require("fs").readFileSync(
    require("path").join(__dirname, "visual.spec.js"),
    "utf8",
  );
  const lines = source.split("\n");
  const unchecked = [];
  lines.forEach((line, i) => {
    if (!line.includes(".toHaveScreenshot(")) return;
    if (lines[i - 1].trim() !== "await expectAccessible(page);") {
      unchecked.push(`visual.spec.js:${i + 1}`);
    }
  });
  expect(unchecked, "screenshots with no axe check just before").toEqual([]);
});
