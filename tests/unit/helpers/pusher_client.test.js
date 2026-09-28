import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

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

  it("loads pusher-js itself when no stub is present", async () => {
    const Fake = fakePusherClass();
    vi.doMock("pusher-js", () => ({ default: Fake }));
    const { pusherClient, startPusher } = await freshClient({ key: "k" });
    pusherClient.subscribe("meal-3");

    startPusher();
    // The import resolves a moment later.
    await vi.waitFor(() => expect(Fake.instances).toHaveLength(1));
    expect(Fake.instances[0].calls).toEqual([["subscribe", "meal-3"]]);
    expect(pusherClient.connection.socket_id).toBe("socket-1");
    vi.doUnmock("pusher-js");
  });
});
