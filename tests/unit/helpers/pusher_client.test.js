import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

// The Pusher transport. Each test gets a fresh module (the client keeps
// `started` and the real instance at module level) and its own env.
async function freshClient(env) {
  vi.resetModules();
  vi.stubEnv("VITE_PUSHER_KEY", env.key);
  vi.stubEnv("VITE_PUSHER_CLUSTER", "us3");
  return import("../../../app/frontend/src/helpers/pusher_client.js");
}

function fakePusherClass() {
  const instances = [];
  function FakePusher(key, options) {
    this.key = key;
    this.options = options;
    this.connection = { bind: vi.fn(), socket_id: "socket-1" };
    this.subscribe = vi.fn(() => ({ bind: vi.fn() }));
    this.unsubscribe = vi.fn();
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
    expect(real.options).toEqual({ cluster: "us3", encrypted: true });
    expect(real.subscribe).toHaveBeenCalledWith("meal-1");
    expect(real.connection.bind).toHaveBeenCalledWith("state_change", onState);
    expect(real.unsubscribe).toHaveBeenCalledWith("meal-1");
    expect(pusherClient.connection.socket_id).toBe("socket-1");

    // After the connection, calls go straight through.
    pusherClient.subscribe("meal-2");
    expect(real.subscribe).toHaveBeenLastCalledWith("meal-2");
  });

  it("loads pusher-js itself when no stub is present", async () => {
    const Fake = fakePusherClass();
    vi.doMock("pusher-js", () => ({ default: Fake }));
    const { pusherClient, startPusher } = await freshClient({ key: "k" });
    pusherClient.subscribe("meal-3");

    startPusher();
    // The import resolves a moment later.
    await vi.waitFor(() => expect(Fake.instances).toHaveLength(1));
    expect(Fake.instances[0].subscribe).toHaveBeenCalledWith("meal-3");
    expect(pusherClient.connection.socket_id).toBe("socket-1");
    vi.doUnmock("pusher-js");
  });
});
