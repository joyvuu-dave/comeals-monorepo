import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";

vi.mock("axios", () => import("../mocks/axios.js"));
vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));
vi.mock("pusher-js", () => import("../mocks/pusher.js"));
vi.mock("idb-keyval", () => import("../mocks/idb_keyval.js"));
import { stubRandomUUID } from "../mocks/uuid.js";
stubRandomUUID();

import axios from "axios";
import Cookie from "js-cookie";
import { createDataStore, stage } from "../helpers/create_data_store.js";
import { pusherClient } from "../../../app/frontend/src/helpers/pusher_client.js";
import toastStore from "../../../app/frontend/src/stores/toast_store.js";

// The hosts cache (data_store_hosts.js): the adult-residents list the
// reservation modals show. The interesting behavior is concurrency —
// deduping concurrent fetches, superseding stale responses — which is
// exactly the kind of logic that breaks without a test noticing.

const WIRE_HOSTS = [
  [1, "Jane Smith", "A"],
  [2, "Bob Johnson", "B"],
];

function mockHostsResponse(data = WIRE_HOSTS) {
  axios.get.mockResolvedValue({ status: 200, data });
}

describe("hosts cache", () => {
  let store;

  beforeEach(() => {
    vi.clearAllMocks();
    store = createDataStore();
  });

  afterEach(() => {
    axios.get.mockReset();
    if (vi.isMockFunction(pusherClient.subscribe)) {
      pusherClient.subscribe.mockRestore();
    }
  });

  it("ensureHosts fetches once and names the tuple fields", async () => {
    mockHostsResponse();
    const hosts = await store.ensureHosts();

    expect(axios.get).toHaveBeenCalledTimes(1);
    expect(axios.get.mock.calls[0][0]).toMatch(/\/hosts$/);
    expect(hosts.slice()).toEqual([
      { id: 1, name: "Jane Smith", unitName: "A" },
      { id: 2, name: "Bob Johnson", unitName: "B" },
    ]);
    expect(store.hostsLoaded).toBe(true);
  });

  // Logout removes the session cookies just before the page reloads, and
  // a calendar that mounts in between asks for the hosts. That request
  // named the community "undefined" (#153).
  it("sends no request without a community id, and keeps the list it has", async () => {
    mockHostsResponse();
    await store.ensureHosts();
    axios.get.mockClear();
    Cookie.remove("token");
    Cookie.remove("community_id");

    const fresh = createDataStore();
    const freshHosts = await fresh.ensureHosts();
    const keptHosts = await store.refetchHostsSilently();

    expect(axios.get).not.toHaveBeenCalled();
    expect(freshHosts.slice()).toEqual([]);
    expect(fresh.hostsLoaded).toBe(false);
    expect(keptHosts.slice()).toEqual([
      { id: 1, name: "Jane Smith", unitName: "A" },
      { id: 2, name: "Bob Johnson", unitName: "B" },
    ]);
    fresh.beforeDestroy();
  });

  it("a warm cache resolves without a second request", async () => {
    mockHostsResponse();
    await store.ensureHosts();
    await store.ensureHosts();

    expect(axios.get).toHaveBeenCalledTimes(1);
  });

  it("concurrent ensureHosts callers share one request", async () => {
    mockHostsResponse();
    const [a, b] = await Promise.all([
      store.ensureHosts(),
      store.ensureHosts(),
    ]);

    expect(axios.get).toHaveBeenCalledTimes(1);
    expect(a).toBe(b);
  });

  it("refetchHostsSilently supersedes an in-flight fetch", async () => {
    // First request hangs until released; the silent refetch starts a
    // second request that resolves first with newer data. The slow
    // response must NOT overwrite the newer list when it finally lands.
    let releaseFirst;
    const firstResponse = new Promise((resolve) => {
      releaseFirst = resolve;
    });
    axios.get
      .mockImplementationOnce(() => firstResponse)
      .mockImplementationOnce(() =>
        Promise.resolve({ status: 200, data: [[3, "Alice Williams", "C"]] }),
      );

    const slow = store.ensureHosts();
    const fast = store.refetchHostsSilently();
    await fast;

    expect(store.hosts.slice()).toEqual([
      { id: 3, name: "Alice Williams", unitName: "C" },
    ]);

    // The superseded response arrives late — and is discarded.
    releaseFirst({ status: 200, data: WIRE_HOSTS });
    await slow;
    expect(store.hosts.slice()).toEqual([
      { id: 3, name: "Alice Williams", unitName: "C" },
    ]);
    expect(axios.get).toHaveBeenCalledTimes(2);
  });

  // The refetch runs in the background (a Pusher update, a reconnect,
  // midnight), so a network failure must not put a toast on the shared
  // screen: the next update or reconnect fetches again.
  it("a failed refetch keeps the previously loaded list, silently", async () => {
    mockHostsResponse();
    await store.ensureHosts();
    toastStore.clearAll();

    const consoleError = vi
      .spyOn(console, "error")
      .mockImplementation(() => {});
    // What axios rejects with when no answer came back.
    axios.get.mockRejectedValueOnce({ request: {} });
    const result = await store.refetchHostsSilently();

    const loaded = [
      { id: 1, name: "Jane Smith", unitName: "A" },
      { id: 2, name: "Bob Johnson", unitName: "B" },
    ];
    expect(result.slice()).toEqual(loaded);
    expect(store.hosts.slice()).toEqual(loaded);
    expect(store.hostsLoaded).toBe(true);
    expect(toastStore.toasts).toEqual([]);
    expect(consoleError).toHaveBeenCalledWith(
      "Error: no response received from server.",
    );
    consoleError.mockRestore();
  });

  it("subscribes the residents channel once and refetches on update", async () => {
    const bind = vi.fn();
    vi.spyOn(pusherClient, "subscribe").mockImplementation(() => ({ bind }));
    // No meal on screen: the residents channel also refetches the meal
    // page and the calendar when they are up (live_updates.test.js).
    stage(store, () => {
      store.meal = null;
    });
    mockHostsResponse();
    await store.ensureHosts();

    expect(window.Comeals.pusher.subscribe).toHaveBeenCalledTimes(1);
    expect(window.Comeals.pusher.subscribe.mock.calls[0][0]).toMatch(
      /-residents$/,
    );
    expect(bind).toHaveBeenCalledWith("update", expect.any(Function));

    // The bound handler refreshes the cache. It returns nothing to wait
    // on, so wait for the new list itself.
    mockHostsResponse([[9, "New Person", "B"]]);
    const handler = bind.mock.calls[0][1];
    handler();
    await vi.waitFor(() => {
      expect(store.hosts.slice()).toEqual([
        { id: 9, name: "New Person", unitName: "B" },
      ]);
    });

    // A second successful fetch does not resubscribe.
    await store.refetchHostsSilently();
    expect(window.Comeals.pusher.subscribe).toHaveBeenCalledTimes(1);
  });
});
