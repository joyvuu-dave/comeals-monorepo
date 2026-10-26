import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { vitestWaitFor } from "./wait_for.js";
import { fakeLocation } from "./fake_location.js";

// The Pusher transport. Each test gets a fresh module (the client keeps
// `started` and the real instance at module level) and its own env.
async function freshClient(env) {
  vi.resetModules();
  vi.stubEnv("VITE_PUSHER_KEY", env.key);
  vi.stubEnv("VITE_PUSHER_CLUSTER", "us3");
  return import("../../../app/frontend/src/helpers/pusher_client.js");
}

// A fake pusher-js class. Like pusher-js, subscribe returns the one
// channel it keeps under that name, so a test can see what was bound on
// it. Every call to the fake goes into `calls`, in order.
function fakePusherClass() {
  const instances = [];
  function FakePusher(key, options) {
    this.key = key;
    this.options = options;
    this.calls = [];
    this.channels = {};
    this.connection = {
      bind: vi.fn((event) => this.calls.push(["connection.bind", event])),
      socket_id: "socket-1",
    };
    this.subscribe = vi.fn((name) => {
      this.calls.push(["subscribe", name]);
      this.channels[name] ||= {
        bind: vi.fn((event) => this.calls.push(["bind", name, event])),
      };
      return this.channels[name];
    });
    this.unsubscribe = vi.fn((name) => this.calls.push(["unsubscribe", name]));
    instances.push(this);
  }
  FakePusher.instances = instances;
  return FakePusher;
}

describe("pusherClient", () => {
  beforeEach(() => {
    delete window.Pusher;
  });

  afterEach(() => {
    vi.unstubAllEnvs();
    delete window.Pusher;
  });

  it("has no socket_id before the library is connected", async () => {
    const { pusherClient } = await freshClient({ key: "" });
    expect(pusherClient.connection.socket_id).toBeNull();
  });

  it("never connects without a key, and queued calls stay queued", async () => {
    window.Pusher = fakePusherClass();
    const { pusherClient, startPusher } = await freshClient({ key: "" });
    pusherClient.subscribe("meal-1").bind("update", () => {});
    startPusher();
    expect(window.Pusher.instances).toHaveLength(0);
    expect(pusherClient.connection.socket_id).toBeNull();
  });

  it("connects through window.Pusher when a test stub provides one, replaying queued calls in order", async () => {
    window.Pusher = fakePusherClass();
    const { pusherClient, startPusher } = await freshClient({ key: "k" });
    const onUpdate = () => {};
    const onState = () => {};
    pusherClient.subscribe("meal-1").bind("update", onUpdate);
    pusherClient.connection.bind("state_change", onState);
    pusherClient.unsubscribe("meal-1");

    startPusher();
    startPusher(); // a second start is a no-op

    expect(window.Pusher.instances).toHaveLength(1);
    const real = window.Pusher.instances[0];
    expect(real.key).toBe("k");
    expect(real.options).toEqual({ cluster: "us3" });
    // The queue replays in the order the calls were made. (The bind
    // finds its channel with subscribe, as pusher-js allows.)
    expect(real.calls).toEqual([
      ["subscribe", "meal-1"],
      ["subscribe", "meal-1"],
      ["bind", "meal-1", "update"],
      ["connection.bind", "state_change"],
      ["unsubscribe", "meal-1"],
    ]);
    // The exact handlers reach the real channel and connection.
    expect(real.channels["meal-1"].bind).toHaveBeenCalledWith(
      "update",
      onUpdate,
    );
    expect(real.connection.bind).toHaveBeenCalledWith("state_change", onState);
    expect(pusherClient.connection.socket_id).toBe("socket-1");
  });

  it("after connecting, sends every call straight through", async () => {
    window.Pusher = fakePusherClass();
    const { pusherClient, startPusher } = await freshClient({ key: "k" });
    startPusher();
    const real = window.Pusher.instances[0];
    const onUpdate = () => {};

    pusherClient.subscribe("meal-2").bind("update", onUpdate);
    pusherClient.unsubscribe("meal-2");

    expect(real.calls).toEqual([
      ["subscribe", "meal-2"],
      ["subscribe", "meal-2"],
      ["bind", "meal-2", "update"],
      ["unsubscribe", "meal-2"],
    ]);
    expect(real.channels["meal-2"].bind).toHaveBeenCalledWith(
      "update",
      onUpdate,
    );
  });

  // Two callers can hold one channel (the month on screen was a
  // neighbour a moment ago). pusher-js subscribes a name once, so the
  // wrapper does too.
  it("hands every caller the same wrapper for a name, and subscribes it once", async () => {
    window.Pusher = fakePusherClass();
    const { pusherClient, startPusher } = await freshClient({ key: "k" });
    startPusher();
    const real = window.Pusher.instances[0];

    const first = pusherClient.subscribe("meal-3");
    const second = pusherClient.subscribe("meal-3");

    expect(second).toBe(first);
    expect(first.name).toBe("meal-3");
    expect(real.calls).toEqual([["subscribe", "meal-3"]]);

    // After an unsubscribe the name gets a new wrapper and a new
    // subscription.
    pusherClient.unsubscribe("meal-3");
    const third = pusherClient.subscribe("meal-3");
    expect(third).not.toBe(first);
    expect(real.calls).toEqual([
      ["subscribe", "meal-3"],
      ["unsubscribe", "meal-3"],
      ["subscribe", "meal-3"],
    ]);
  });

  // The library loads after the page's load event, when the main thread
  // is idle, so its download does not compete with the first screen.
  describe("when pusher-js loads", () => {
    let Fake;

    beforeEach(() => {
      Fake = fakePusherClass();
      vi.doMock("pusher-js", () => ({ default: Fake }));
    });

    afterEach(() => {
      vi.doUnmock("pusher-js");
      vi.restoreAllMocks();
      delete window.requestIdleCallback;
    });

    async function settle() {
      for (let i = 0; i < 5; i++) await new Promise((r) => setTimeout(r, 0));
    }

    it("waits for the load event, then for an idle moment", async () => {
      const readyState = vi
        .spyOn(document, "readyState", "get")
        .mockReturnValue("loading");
      const idle = [];
      window.requestIdleCallback = vi.fn((callback, options) => {
        idle.push([callback, options]);
      });
      const { pusherClient, startPusher } = await freshClient({ key: "k" });
      pusherClient.subscribe("meal-4");

      startPusher();
      await settle();
      expect(window.requestIdleCallback).not.toHaveBeenCalled();

      readyState.mockReturnValue("complete");
      window.dispatchEvent(new Event("load"));
      expect(idle).toHaveLength(1);
      // An idle moment may never come on a busy page, so it is not
      // waited for longer than this.
      expect(idle[0][1]).toEqual({ timeout: 2000 });
      await settle();
      expect(Fake.instances).toHaveLength(0);

      idle[0][0]();
      await vitestWaitFor(() => expect(Fake.instances).toHaveLength(1));
      // What was asked for while it loaded is sent once it connects.
      expect(Fake.instances[0].calls).toEqual([["subscribe", "meal-4"]]);
    });

    it("waits only for an idle moment when the page has already loaded", async () => {
      const idle = [];
      window.requestIdleCallback = vi.fn((callback) => idle.push(callback));
      const { startPusher } = await freshClient({ key: "k" });

      startPusher();
      expect(idle).toHaveLength(1);
      await settle();
      expect(Fake.instances).toHaveLength(0);

      idle[0]();
      await vitestWaitFor(() => expect(Fake.instances).toHaveLength(1));
    });
  });

  // pusher-js is its own file (a chunk). After a deploy, a page loaded
  // before it can ask for a chunk the server no longer has, and a phone
  // on a bad network can fail to get it. The page then reloads once, the
  // same as when a page's code fails (lazy_retry.ts). Without this the
  // page ran with no live updates, and the failed import reached Bugsnag
  // as an unhandled rejection ("Importing a module script failed." in
  // Safari, on the login page at "/").
  describe("when pusher-js fails to load", () => {
    let fake;
    let notifyError;

    beforeEach(() => {
      sessionStorage.clear();
      fake = fakeLocation();
      vi.stubGlobal("__BUILD_ID__", "build-2");
      // The server answers, so the reload goes ahead at once.
      vi.stubGlobal(
        "fetch",
        vi.fn(() => Promise.resolve({ ok: true, status: 200 })),
      );
      vi.doMock("pusher-js", () => {
        throw new TypeError("Importing a module script failed.");
      });
      notifyError = vi.fn();
      vi.doMock("../../../app/frontend/src/helpers/bugsnag", () => ({
        notifyError,
      }));
    });

    afterEach(() => {
      vi.doUnmock("pusher-js");
      vi.doUnmock("../../../app/frontend/src/helpers/bugsnag");
      vi.unstubAllGlobals();
      fake.restore();
      sessionStorage.clear();
    });

    it("reloads once, after beforeReload, and reports nothing", async () => {
      const { startPusher } = await freshClient({ key: "k" });
      const beforeReload = vi.fn();

      startPusher(beforeReload);

      await vitestWaitFor(() =>
        expect(fake.location.reload).toHaveBeenCalledTimes(1),
      );
      // The reload ends every request on its way, so the bills saves
      // are handed to the browser first (#150).
      expect(beforeReload).toHaveBeenCalledTimes(1);
      expect(beforeReload.mock.invocationCallOrder[0]).toBeLessThan(
        fake.location.reload.mock.invocationCallOrder[0],
      );
      expect(sessionStorage.getItem("chunk_retry")).toBe("build-2");
      expect(notifyError).not.toHaveBeenCalled();
    });

    // The page already reloaded once in this build, and that did not
    // help. The page goes on without live updates, and the failure goes
    // to Bugsnag once, as a caught error.
    it("reports to Bugsnag, with no reload, when it fails again after the reload", async () => {
      sessionStorage.setItem("chunk_retry", "build-2");
      const { startPusher } = await freshClient({ key: "k" });
      const beforeReload = vi.fn();

      startPusher(beforeReload);

      await vitestWaitFor(() => expect(notifyError).toHaveBeenCalledTimes(1));
      expect(notifyError.mock.calls[0][0]).toBeInstanceOf(Error);
      expect(beforeReload).not.toHaveBeenCalled();
      expect(fake.location.reload).not.toHaveBeenCalled();
    });
    // A browser that blocks site data cannot remember a reload, so a
    // reload could repeat with no end. The page never reloads; the
    // failure goes to Bugsnag once and the page runs with no live
    // updates.
    it("reports to Bugsnag, with no reload, when the browser refuses sessionStorage", async () => {
      vi.spyOn(window, "sessionStorage", "get").mockImplementation(() => {
        throw new DOMException("The operation is insecure.", "SecurityError");
      });
      const { startPusher } = await freshClient({ key: "k" });
      const beforeReload = vi.fn();

      startPusher(beforeReload);

      await vitestWaitFor(() => expect(notifyError).toHaveBeenCalledTimes(1));
      expect(notifyError.mock.calls[0][0]).toBeInstanceOf(Error);
      expect(notifyError.mock.calls[0][0]).not.toBeInstanceOf(DOMException);
      expect(beforeReload).not.toHaveBeenCalled();
      expect(fake.location.reload).not.toHaveBeenCalled();
      vi.restoreAllMocks();
    });
  });

  // Safari has no requestIdleCallback; there it loads on the next turn.
  it("loads pusher-js itself when no stub is present", async () => {
    const Fake = fakePusherClass();
    vi.doMock("pusher-js", () => ({ default: Fake }));
    const { pusherClient, startPusher } = await freshClient({ key: "k" });
    pusherClient.subscribe("meal-3");

    startPusher();
    // The import resolves a moment later.
    await vitestWaitFor(() => expect(Fake.instances).toHaveLength(1));
    expect(Fake.instances[0].calls).toEqual([["subscribe", "meal-3"]]);
    expect(pusherClient.connection.socket_id).toBe("socket-1");
    vi.doUnmock("pusher-js");
  });
});
