import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { act, screen } from "@testing-library/react";

vi.mock("axios", () => import("./mocks/axios.js"));
vi.mock("js-cookie", () => import("./mocks/js_cookie.js"));
vi.mock("pusher-js", () => import("./mocks/pusher.js"));
vi.mock("idb-keyval", () => import("./mocks/idb_keyval.js"));
vi.mock("../../app/frontend/src/helpers/bugsnag", () => ({
  startBugsnag: vi.fn(),
  notifyError: vi.fn(),
}));

import { fakeLocation } from "./helpers/fake_location.js";

// A crash in a part of the page outside ErrorBoundary, which is around
// the routes only. Before OuterErrorBoundary, such a crash took the
// whole page away, its idle timer too, and the root was left empty
// (<div id="root"></div>): a shared screen stayed blank until someone
// came and reloaded it. These tests boot the real index.jsx, so they
// read the tree as the app builds it.
const MINUTE = 60 * 1000;

// Boots the app the way the browser does. index.jsx waits for
// DOMContentLoaded, which jsdom fired before any test ran, so the
// listener is taken and called here. Each boot loads a fresh copy of
// the app's modules into a fresh #root.
async function bootApp() {
  vi.resetModules();
  // Signed out: the app opens on the login page, with every part of
  // the page around the routes (the message stack, the banners, the
  // idle timer). The cookie jar is a fresh copy after the reset.
  const { cookies } = await import("./mocks/js_cookie.js");
  cookies.current = { timezone: "America/Los_Angeles" };
  document.getElementById("root")?.remove();
  const root = document.createElement("div");
  root.id = "root";
  document.body.appendChild(root);

  const addEventListener = document.addEventListener.bind(document);
  let boot;
  const spy = vi
    .spyOn(document, "addEventListener")
    .mockImplementation((type, listener, options) => {
      if (type === "DOMContentLoaded") {
        boot = listener;
        return;
      }
      addEventListener(type, listener, options);
    });
  await import("../../app/frontend/src/index.jsx");
  spy.mockRestore();
  return { root, thrown: await caught(async () => boot()) };
}

// The error that went through React's act() uncaught, or null. Before
// OuterErrorBoundary, such an error took the whole page away.
async function caught(work) {
  try {
    await act(work);
    return null;
  } catch (error) {
    return error;
  }
}

const EMPTY_ROOT = '<div id="root"></div>';

function crashPage() {
  return screen.queryByText("Something went wrong with Comeals.");
}

describe("a crash outside the error page", () => {
  let location;
  let restoreLocation;

  beforeEach(() => {
    vi.useFakeTimers();
    // The build the device last saw is this one, so the boot does not
    // empty the month cache (jsdom has no IndexedDB).
    vi.stubGlobal("__BUILD_ID__", "test-build");
    localStorage.setItem("cacheVersion", "test-build");
    sessionStorage.clear();
    vi.spyOn(console, "error").mockImplementation(() => {});
    restoreLocation = () => {};
  });

  afterEach(() => {
    restoreLocation();
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
    vi.doUnmock(
      "../../app/frontend/src/components/app/session_expired_banner.jsx",
    );
    vi.useRealTimers();
    sessionStorage.clear();
  });

  // The message stack measures itself once a message shows. Here that
  // throws, the way a broken stack would.
  it("in the message stack shows the crash page, reports it, and loads '/' after five minutes", async () => {
    vi.stubGlobal(
      "ResizeObserver",
      class {
        observe() {
          throw new Error("the message stack broke");
        }
        disconnect() {}
      },
    );
    const { root } = await bootApp();
    expect(screen.getByLabelText("email")).toBeInTheDocument();

    const toastStore = (
      await import("../../app/frontend/src/stores/toast_store")
    ).default;
    const thrown = await caught(async () =>
      toastStore.show("Email required.", "error"),
    );

    expect(root.outerHTML).not.toBe(EMPTY_ROOT);
    expect(thrown).toBeNull();
    expect(crashPage()).toBeInTheDocument();
    const { notifyError } =
      await import("../../app/frontend/src/helpers/bugsnag");
    expect(notifyError).toHaveBeenCalledTimes(1);
    expect(vi.mocked(notifyError).mock.lastCall[0].message).toBe(
      "the message stack broke",
    );

    // jsdom does not load pages. The router is gone with the crash, so
    // a stand-in for window.location can take its place now.
    ({ location, restore: restoreLocation } = fakeLocation({
      assign: vi.fn(),
    }));

    await act(async () => {
      await vi.advanceTimersByTimeAsync(5 * MINUTE);
    });
    expect(location.assign).toHaveBeenCalledWith("/");
  });

  // The signed-out banner draws outside the routes too.
  it("in the signed-out banner shows the crash page", async () => {
    vi.doMock(
      "../../app/frontend/src/components/app/session_expired_banner.jsx",
      () => ({
        default: function SessionExpiredBanner() {
          throw new Error("the banner broke");
        },
      }),
    );
    const { root, thrown } = await bootApp();
    expect(root.outerHTML).not.toBe(EMPTY_ROOT);
    expect(thrown).toBeNull();
    expect(crashPage()).toBeInTheDocument();
  });

  // A page that runs an hour without a crash forgets the crashes before
  // it (helpers/crash_reload_wait.ts). The app starts that hour when it
  // boots.
  it("is forgotten once the page has run an hour without one", async () => {
    sessionStorage.setItem("crashReloads", "3");
    await bootApp();

    await act(async () => {
      await vi.advanceTimersByTimeAsync(60 * MINUTE);
    });
    expect(sessionStorage.getItem("crashReloads")).toBeNull();
  });
});
