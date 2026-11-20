// @ts-check
import { defineConfig } from "@playwright/test";
import ports from "./tests/helpers/ports.js";

/**
 * VoiceOver tests (challenge 32). They run the real macOS VoiceOver
 * against Safari's engine, on the real Rails test server, through
 * Guidepup. Run them with bin/test-voiceover, which seeds, starts the
 * server and stops it afterwards.
 *
 * VoiceOver reads whatever window has focus, so a run brings the
 * browser to the front and needs the laptop to itself until it ends.
 */
export default defineConfig({
  testDir: "./tests/voiceover",
  timeout: 180_000,
  expect: { timeout: 5_000 },
  fullyParallel: false,
  // One VoiceOver for the whole Mac, so one test at a time.
  workers: 1,
  retries: 0,
  reporter: [["list"]],
  outputDir: "test-results/voiceover",
  use: {
    baseURL: `http://localhost:${ports.INTEGRATION_PORT}`,
    // VoiceOver reads only a window it can see.
    headless: false,
    browserName: "webkit",
    timezoneId: "America/Los_Angeles",
    screenshot: "only-on-failure",
    trace: "retain-on-failure",
  },
});
