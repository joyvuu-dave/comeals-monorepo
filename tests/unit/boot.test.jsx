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

// Each test here loads the whole app fresh (vi.resetModules, then
// index.jsx). Under load that takes longer than Vitest's default limit
// of 5 seconds, and a test stopped at its limit keeps running into the
// tests after it (#247).
vi.setConfig({ testTimeout: 60_000 });

// How index.jsx starts the app: the router, the store, the boot-time
// month download, the check for a new build, the online and offline
// listeners, and the removal of old service workers. app_crash.test.jsx
// boots the same file to test crashes; this file tests a boot that works.

const SRC = "../../app/frontend/src";

// The store the booted page made. index.jsx hands it to
// sendBillsOnPageClose before anything else, and the spy below keeps it.
let bootedStore = null;

// The two pages index.jsx loads with React.lazy. Their own tests cover
// them; here each one only says which page it is. `failingPage` names
// a page whose code fails to load, the way it does after a deploy.
function mockPages(failingPage) {
  const pages = {
    "calendar/show": "the calendar page",
    "meals/edit": "the meal page",
  };
  for (const [page, heading] of Object.entries(pages)) {
    vi.doMock(`${SRC}/components/${page}`, () => {
      if (page === failingPage) failingPageLoad();
      return {
        default: function Page() {
          return <h1>{heading}</h1>;
        },
      };
    });
  }
}

let failingPageLoad = () => {};

// The mobx-state-tree copy the booted page uses.
let mst = null;

// The real modules, with a spy where a test reads what index.jsx asked
// for. Each boot loads fresh copies, so these come back with the boot.
function mockSpies() {
  vi.doMock(`${SRC}/stores/month_fetch`, async (importOriginal) => ({
    ...(await importOriginal()),
    prefetchMonth: vi.fn(),
  }));
  vi.doMock("mobx-state-tree", async (importOriginal) => {
    const original = await importOriginal();
    mst = original;
    return {
      ...original,
      setLivelinessChecking: vi.fn(original.setLivelinessChecking),
    };
  });
  vi.doMock(
    `${SRC}/helpers/send_bills_on_page_close`,
    async (importOriginal) => {
      const original = await importOriginal();
      return {
        ...original,
        sendBillsOnPageClose: vi.fn(function (store) {
          bootedStore = store;
          return original.sendBillsOnPageClose(store);
        }),
      };
    },
  );
}

// Boots the app the way the browser does, at `path`. index.jsx waits
// for DOMContentLoaded and for load, which jsdom fired before any test
// ran, so the listeners are taken here. The test calls `pageLoad`.
// `signedOut` boots with no session cookies.
async function bootApp(path, { failingPage, signedOut = false } = {}) {
  vi.resetModules();
  bootedStore = null;
  // Set through "js-cookie", the module the app reads. Its mock can keep
  // an older copy of the cookie jar across the reset, one that
  // render_setup.js does not put back after a test, so every boot sets
  // both cookies itself.
  const Cookie = (await import("js-cookie")).default;
  if (signedOut) {
    Cookie.remove("token");
    Cookie.remove("community_id");
  } else {
    Cookie.set("token", "test-token");
    Cookie.set("community_id", "test-community-id");
  }
  mockPages(failingPage);
  mockSpies();
  // The idb-keyval mock keeps one copy across the reset too, with the
  // calls of earlier boots.
  vi.mocked((await import("idb-keyval")).clear).mockClear();
  window.history.replaceState(null, "", path);
  document.getElementById("root")?.remove();
  const root = document.createElement("div");
  root.id = "root";
  document.body.appendChild(root);

  const addDocumentListener = document.addEventListener.bind(document);
  let domReady;
  const documentSpy = vi
    .spyOn(document, "addEventListener")
    .mockImplementation((type, listener, options) => {
      if (type === "DOMContentLoaded") {
        domReady = listener;
        return;
      }
      addDocumentListener(type, listener, options);
    });
  const addWindowListener = window.addEventListener.bind(window);
  let pageLoad;
  const windowSpy = vi
    .spyOn(window, "addEventListener")
    .mockImplementation((type, listener, options) => {
      if (type === "load") {
        pageLoad = listener;
        return;
      }
      addWindowListener(type, listener, options);
    });

  await import(`${SRC}/index.jsx`);
  documentSpy.mockRestore();
  await act(async () => domReady());
  windowSpy.mockRestore();
  return { store: bootedStore, pageLoad };
}

async function loaded(name) {
  return await screen.findByRole("heading", { name });
}

beforeEach(() => {
  vi.stubGlobal("__BUILD_ID__", "test-build");
  localStorage.setItem("cacheVersion", "test-build");
  sessionStorage.clear();
  vi.spyOn(console, "warn").mockImplementation(() => {});
  // ScrollToTop scrolls on every route, and jsdom does not scroll.
  vi.spyOn(window, "scrollTo").mockImplementation(() => {});
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  vi.unstubAllEnvs();
  vi.doUnmock(`${SRC}/components/calendar/show`);
  vi.doUnmock(`${SRC}/components/meals/edit`);
  vi.doUnmock(`${SRC}/stores/month_fetch`);
  vi.doUnmock("mobx-state-tree");
  vi.doUnmock(`${SRC}/helpers/send_bills_on_page_close`);
  localStorage.clear();
  sessionStorage.clear();
  window.history.replaceState(null, "", "/");
});

describe("the routes", () => {
  it("shows the calendar to a signed-in person", async () => {
    await bootApp("/calendar/all/2026-10-01/");
    expect(await loaded("the calendar page")).toBeInTheDocument();
  });

  it("shows a meal to a signed-in person", async () => {
    await bootApp("/meals/12/edit/");
    expect(await loaded("the meal page")).toBeInTheDocument();
  });

  it("sends a signed-out person from the calendar to the login page", async () => {
    await bootApp("/calendar/all/2026-10-01/", { signedOut: true });
    expect(await screen.findByLabelText("email")).toBeInTheDocument();
    expect(window.location.pathname).toBe("/");
  });

  // Every route ends in "/". A path without one gets it, and the
  // query string stays.
  it("adds the missing slash at the end of a path", async () => {
    await bootApp("/calendar/all/2026-10-01?view=month");
    expect(await loaded("the calendar page")).toBeInTheDocument();
    expect(window.location.pathname).toBe("/calendar/all/2026-10-01/");
    expect(window.location.search).toBe("?view=month");
  });

  it("leaves a path that ends in a slash alone", async () => {
    await bootApp("/meals/12/edit/");
    await loaded("the meal page");
    expect(window.location.pathname).toBe("/meals/12/edit/");
  });
});

// React 19 shows a Suspense fallback for a lazy page on its first
// render, even when the page's code is already loaded, and then waits
// until 300 ms have passed since it showed the fallback before it shows
// the page. A page that starts on the calendar loads the calendar's code
// before the first render, so the calendar is the first thing React
// draws, without that wait. The static shell in index.html says
// "Loading..." until then.
describe("the calendar's first render", () => {
  let observer = null;

  afterEach(() => {
    observer?.disconnect();
    observer = null;
    vi.doUnmock("react-dom/client");
  });

  // Every text React adds to the root, in order.
  function watchRoot() {
    const added = [];
    observer = new MutationObserver(function (records) {
      for (const record of records) {
        for (const node of record.addedNodes) added.push(node.textContent);
      }
    });
    return {
      added,
      start() {
        observer.observe(document.getElementById("root"), {
          childList: true,
          subtree: true,
        });
      },
    };
  }

  it("never shows the Suspense fallback on a calendar address", async () => {
    const watch = watchRoot();
    const realAppend = document.body.appendChild.bind(document.body);
    vi.spyOn(document.body, "appendChild").mockImplementation((node) => {
      const result = realAppend(node);
      if (node.id === "root") watch.start();
      return result;
    });
    await bootApp("/calendar/all/2026-10-01/");
    expect(await loaded("the calendar page")).toBeInTheDocument();
    expect(watch.added.join("|")).not.toContain("Loading...");
  });

  // The render now waits for the calendar's code, so it runs after
  // startApp's try has ended. A crash in it must still draw the crash
  // page instead of leaving the screen blank (#162).
  it("shows the crash page when the first render crashes", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    vi.doMock("react-dom/client", () => ({
      createRoot() {
        throw new Error("the render broke");
      },
    }));
    await bootApp("/calendar/all/2026-10-01/");
    expect(
      await screen.findByText("Something went wrong with Comeals."),
    ).toBeInTheDocument();
    const { notifyError } = await import(`${SRC}/helpers/bugsnag`);
    expect(vi.mocked(notifyError).mock.lastCall[0].message).toBe(
      "the render broke",
    );
  });

  // If the calendar's code fails to load here, the page renders anyway,
  // and the lazy page's own retry handles it (the next describe).
  it("renders the app when the calendar's code fails to load", async () => {
    failingPageLoad = function () {
      throw new Error("Failed to fetch dynamically imported module");
    };
    vi.stubGlobal(
      "fetch",
      vi.fn(() => new Promise(function () {})),
    );
    await bootApp("/calendar/all/2026-10-01/", {
      failingPage: "calendar/show",
    });
    failingPageLoad = () => {};
    // The lazy page shows its fallback while lazy_retry waits for the
    // server, so the app did render.
    expect(await screen.findByText("Loading...")).toBeInTheDocument();
  });
});

// After a deploy, a page loaded before it can ask for a page's code that
// the server no longer has. The page then loads itself again, and the
// bills saves on their way are sent first (#150, helpers/lazy_retry.ts).
describe("a page whose code fails to load", () => {
  let restoreLocation = () => {};

  afterEach(() => {
    restoreLocation();
    restoreLocation = () => {};
    failingPageLoad = () => {};
  });

  it.each([
    ["the calendar", "/calendar/all/2026-10-01/", "calendar/show"],
    ["a meal", "/meals/12/edit/", "meals/edit"],
  ])(
    "on %s sends the bills saves, then loads the page again",
    async (_name, path, page) => {
      const order = [];
      // The page reloads only once the server answers (lazy_retry.ts).
      vi.stubGlobal(
        "fetch",
        vi.fn(() => Promise.resolve({ ok: true, status: 200 })),
      );
      // The page's code is asked for after the store is made: on a
      // calendar address before the first render, on a meal address
      // after it.
      failingPageLoad = function () {
        mst.onAction(bootedStore, (call) => order.push(call.name));
        // jsdom cannot load a page again; this stands in for it. On a
        // calendar address the router has not read the address yet, so
        // the stand-in has the parts it reads.
        ({ restore: restoreLocation } = fakeLocation({
          origin: "http://localhost:3000",
          href: `http://localhost:3000${path}`,
          pathname: path,
          search: "",
          hash: "",
          reload: vi.fn(() => order.push("reload")),
        }));
        throw new Error("Failed to fetch dynamically imported module");
      };

      await bootApp(path, { failingPage: page });

      await vi.waitFor(() =>
        expect(order).toEqual(["sendBillsAgainBeforeClose", "reload"]),
      );
      expect(sessionStorage.getItem("chunk_retry")).toBe("test-build");
    },
  );
});

// Landing on the calendar starts the month's download at once, beside
// the calendar's code, instead of after it.
describe("the month download at boot", () => {
  async function prefetchMonth() {
    return (await import(`${SRC}/stores/month_fetch`)).prefetchMonth;
  }

  it("starts for the month in the path when a signed-in person lands on the calendar", async () => {
    await bootApp("/calendar/all/2026-10-01/");
    expect(await prefetchMonth()).toHaveBeenCalledExactlyOnceWith("2026-10-01");
  });

  // The download needs the community id, and the page goes to the login
  // page anyway.
  it("does not start for a signed-out person", async () => {
    await bootApp("/calendar/all/2026-10-01/", { signedOut: true });
    expect(await prefetchMonth()).not.toHaveBeenCalled();
  });

  it("does not start on another page", async () => {
    await bootApp("/meals/12/edit/");
    expect(await prefetchMonth()).not.toHaveBeenCalled();
  });
});

// The first load of a new build empties the device's copies of months
// and meals, since the build may have changed what the server sends.
describe("a new build", () => {
  let deleteDatabase;

  beforeEach(() => {
    // jsdom has no IndexedDB.
    deleteDatabase = vi.fn();
    vi.stubGlobal("indexedDB", { deleteDatabase });
  });

  async function clear() {
    return (await import("idb-keyval")).clear;
  }

  it("empties the saved copies once, and remembers the build", async () => {
    localStorage.setItem("cacheVersion", "an-older-build");
    await bootApp("/");
    expect(await clear()).toHaveBeenCalledTimes(1);
    expect(deleteDatabase).toHaveBeenCalledExactlyOnceWith("localforage");
    expect(localStorage.getItem("cacheVersion")).toBe("test-build");
  });

  it("empties them on a device that never saved a build", async () => {
    localStorage.removeItem("cacheVersion");
    await bootApp("/");
    expect(await clear()).toHaveBeenCalledTimes(1);
    expect(localStorage.getItem("cacheVersion")).toBe("test-build");
  });

  it("leaves them alone when the build is the one the device saw", async () => {
    await bootApp("/");
    expect(await clear()).not.toHaveBeenCalled();
    expect(deleteDatabase).not.toHaveBeenCalled();
  });
});

// Once the page has loaded, the browser's online and offline events set
// the store's online flag, and coming back online runs the same
// recovery as a Pusher reconnect.
describe("going offline and online", () => {
  let added = [];
  let onLine;

  beforeEach(() => {
    onLine = vi.spyOn(navigator, "onLine", "get");
  });

  afterEach(() => {
    for (const [type, listener] of added) {
      window.removeEventListener(type, listener);
    }
    added = [];
  });

  async function bootAndLoad() {
    // Signed out, so the recovery fetches nothing.
    const { store, pageLoad } = await bootApp("/", { signedOut: true });
    const addWindowListener = window.addEventListener.bind(window);
    const spy = vi
      .spyOn(window, "addEventListener")
      .mockImplementation((type, listener, options) => {
        added.push([type, listener]);
        addWindowListener(type, listener, options);
      });
    pageLoad();
    spy.mockRestore();
    return store;
  }

  it("listens for both only after the page has loaded", async () => {
    await bootApp("/", { signedOut: true });
    expect(added).toEqual([]);
    await bootAndLoad();
    expect(added.map(([type]) => type).sort()).toEqual(["offline", "online"]);
  });

  it("marks the store offline, then online, and runs the recovery", async () => {
    const store = await bootAndLoad();
    const actions = [];
    mst.onAction(store, (call) => actions.push(call.name));

    onLine.mockReturnValue(false);
    act(() => {
      window.dispatchEvent(new Event("offline"));
    });
    expect(store.isOnline).toBe(false);
    expect(actions).toEqual(["setIsOnline"]);

    onLine.mockReturnValue(true);
    act(() => {
      window.dispatchEvent(new Event("online"));
    });
    expect(store.isOnline).toBe(true);
    expect(actions).toEqual(["setIsOnline", "setIsOnline", "handleReconnect"]);
    expect(console.warn).toHaveBeenCalledWith(
      expect.stringMatching(/^offline at /),
    );
    expect(console.warn).toHaveBeenCalledWith(
      expect.stringMatching(/^back online at /),
    );
  });
});

// Earlier builds installed a service worker. Every boot removes any
// that is still there.
describe("old service workers", () => {
  afterEach(() => {
    delete navigator.serviceWorker;
  });

  it("are all removed", async () => {
    const registrations = [{ unregister: vi.fn() }, { unregister: vi.fn() }];
    Object.defineProperty(navigator, "serviceWorker", {
      configurable: true,
      value: { getRegistrations: () => Promise.resolve(registrations) },
    });
    await bootApp("/", { signedOut: true });
    await vi.waitFor(() => {
      for (const registration of registrations) {
        expect(registration.unregister).toHaveBeenCalledTimes(1);
      }
    });
  });

  it("are not looked for in a browser without service workers", async () => {
    expect("serviceWorker" in navigator).toBe(false);
    await bootApp("/", { signedOut: true });
    expect(await screen.findByLabelText("email")).toBeInTheDocument();
  });
});

// React 19's development build reads detached mobx-state-tree nodes, and
// mobx-state-tree warns about each read. Development turns that warning
// off. A production build keeps it.
describe("the detached-node warning", () => {
  async function setLivelinessChecking() {
    return (await import("mobx-state-tree")).setLivelinessChecking;
  }

  it("is off in development", async () => {
    vi.stubEnv("DEV", true);
    await bootApp("/", { signedOut: true });
    expect(await setLivelinessChecking()).toHaveBeenCalledExactlyOnceWith(
      "ignore",
    );
  });

  it("stays on in a production build", async () => {
    vi.stubEnv("DEV", false);
    await bootApp("/", { signedOut: true });
    expect(await setLivelinessChecking()).not.toHaveBeenCalled();
  });
});

// The browser check in index.html (app/frontend/browser_check.js) runs
// before this file. When it turns the browser away, it has already
// drawn its message in the root, and the app must not draw over it, or
// send errors from a browser it knows cannot run the app.
describe("a browser the browser check turned away", () => {
  afterEach(() => {
    delete window.comealsBrowserCheck;
  });

  async function startBugsnag() {
    return (await import(`${SRC}/helpers/bugsnag`)).startBugsnag;
  }

  it("does not start the app or the error reports", async () => {
    vi.mocked(await startBugsnag()).mockClear();
    window.comealsBrowserCheck = { result: "failed", failed: ["lookbehind"] };
    await bootApp("/", { signedOut: true });
    expect(document.getElementById("root")).toBeEmptyDOMElement();
    expect(bootedStore).toBeNull();
    expect(await startBugsnag()).not.toHaveBeenCalled();
  });

  // "error" means the check itself broke. That says nothing about the
  // browser, so the app starts.
  it("starts the app when the check itself broke", async () => {
    window.comealsBrowserCheck = { result: "error", failed: [] };
    await bootApp("/", { signedOut: true });
    expect(await screen.findByLabelText("email")).toBeInTheDocument();
    expect(await startBugsnag()).toHaveBeenCalled();
  });
});
