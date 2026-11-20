// Signing someone up for dinner with VoiceOver (challenge 32).
//
// The real macOS VoiceOver, moved with its own keys, in Safari's engine,
// against the real Rails test server. axe and the Playwright suites
// read the page's code; this reads what VoiceOver says out loud, which
// is what a blind resident hears. Run it with bin/test-voiceover.
const { voiceOverTest: test } = require("@guidepup/playwright");
const { expect } = require("@playwright/test");
const {
  loadAuthInfo,
  setupAuthenticatedPage,
  gotoMeal,
  mealLoaded,
  mealWritten,
} = require("../helpers/integration_setup");

const auth = loadAuthInfo();

// Press a VoiceOver key until VoiceOver says something that includes
// `words`, and give back what it said. Fails with everything it heard,
// so a failure shows what VoiceOver read instead.
async function moveTo(voiceOver, command, words, tries = 40) {
  const heard = [];
  for (let i = 0; i < tries; i++) {
    await voiceOver.perform(command);
    const said = await voiceOver.lastSpokenPhrase();
    if (said.includes(words)) return said;
    heard.push(said);
  }
  throw new Error(
    `VoiceOver never said "${words}". It said:\n  ${heard.join("\n  ")}`,
  );
}

test("sign someone up for today's dinner from the calendar", async ({
  page,
  context,
  voiceOver,
}) => {
  const mealId = auth.meals.today.id;
  await setupAuthenticatedPage(page, context);
  await page.goto("/calendar/all/2026-01-15/");
  await page
    .getByRole("link", { name: /Dinner/ })
    .first()
    .waitFor();
  await voiceOver.navigateToWebContent();
  const { findNextLink, findNextControl, findPreviousControl } =
    voiceOver.keyboardCommands;

  // Moving from link to link, a dinner says which day it is on. The
  // frozen today is Thursday, January 15 (bin/test-integration).
  const dinner = await moveTo(voiceOver, findNextLink, "Thursday, January 15");
  expect(dinner).toMatch(/^Dinner \d+ attending/);

  const loaded = mealLoaded(page, mealId);
  await voiceOver.act();
  await loaded;
  await expect(page).toHaveURL(new RegExp(`/meals/${mealId}/edit`));

  // The seed leaves Bob off today's dinner.
  const bob = await moveTo(voiceOver, findNextControl, "Bob Johnson");
  expect(bob).toBe("B - Bob Johnson toggle button");

  let saved = mealWritten(page, mealId, "POST", "residents/");
  await voiceOver.act();
  await saved;
  expect(await voiceOver.lastSpokenPhrase()).toBe("selected");
  // Leave the button and come back, so VoiceOver reads it whole again.
  await voiceOver.perform(findPreviousControl);
  await voiceOver.perform(findNextControl);
  expect(await voiceOver.lastSpokenPhrase()).toBe(
    "B - Bob Johnson selected toggle button",
  );

  // Take him off again, so the next run finds the seed as it was.
  saved = mealWritten(page, mealId, "DELETE", "residents/");
  await voiceOver.act();
  await saved;
  await voiceOver.perform(findPreviousControl);
  await voiceOver.perform(findNextControl);
  expect(await voiceOver.lastSpokenPhrase()).toBe(
    "B - Bob Johnson toggle button",
  );
});

test("the cook box says who each control is for", async ({
  page,
  context,
  voiceOver,
}) => {
  // Tomorrow's dinner has Jane as its cook, and two rows with no cook.
  await setupAuthenticatedPage(page, context);
  await gotoMeal(page, auth.meals.tomorrow.id);
  await voiceOver.navigateToWebContent();
  const { findNextControl } = voiceOver.keyboardCommands;

  const heard = [];
  for (let i = 0; i < 20; i++) {
    await voiceOver.perform(findNextControl);
    const said = await voiceOver.lastSpokenPhrase();
    if (said.startsWith("Open / Close Meal")) break;
    heard.push(said);
  }
  const cookBox = heard.join("\n");

  // Jane's row names her, and the empty rows say they have no cook.
  expect(cookBox).toContain("No cost for Jane");
  expect(cookBox).toContain("No cook Select meal cook");
  // Never an internal id, and never the shrug drawn in an empty menu.
  expect(cookBox).not.toMatch(/[0-9a-f]{8}-[0-9a-f]{4}-/);
  expect(cookBox).not.toContain("¯");
});
