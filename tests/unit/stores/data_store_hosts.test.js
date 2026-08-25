import { describe, it, expect, beforeEach, vi } from "vitest";

vi.mock("axios", () => import("../mocks/axios.js"));
vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));
vi.mock("pusher-js", () => import("../mocks/pusher.js"));
vi.mock("idb-keyval", () => import("../mocks/idb_keyval.js"));
import { stubRandomUUID } from "../mocks/uuid.js";
stubRandomUUID();

import axios from "axios";
import { runInAction } from "mobx";
import { createDataStore } from "../helpers/create_data_store.js";

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
    window.Comeals = {
      pusher: { subscribe: vi.fn(() => ({ bind: vi.fn() })) },
    };
    store = createDataStore();
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

  it("a failed refetch keeps the previously loaded list", async () => {
    mockHostsResponse();
    await store.ensureHosts();

    const consoleError = vi
      .spyOn(console, "error")
      .mockImplementation(() => {});
    axios.get.mockRejectedValueOnce(new Error("network down"));
    const result = await store.refetchHostsSilently();

    expect(result.slice()).toHaveLength(2);
    expect(store.hosts.slice()).toHaveLength(2);
    consoleError.mockRestore();
  });

  it("subscribes the residents channel once and refetches on update", async () => {
    const bind = vi.fn();
    window.Comeals.pusher.subscribe = vi.fn(() => ({ bind }));
    // No meal on screen: the residents channel also refetches the meal
    // page and the calendar when they are up (live_updates.test.js).
    runInAction(() => {
      store.meal = null;
    });
    mockHostsResponse();
    await store.ensureHosts();

    expect(window.Comeals.pusher.subscribe).toHaveBeenCalledTimes(1);
    expect(window.Comeals.pusher.subscribe.mock.calls[0][0]).toMatch(
      /-residents$/,
    );
    expect(bind).toHaveBeenCalledWith("update", expect.any(Function));

    // The bound handler refreshes the cache.
    mockHostsResponse([[9, "New Person", "B"]]);
    const handler = bind.mock.calls[0][1];
    await handler();
    expect(store.hosts.slice()).toEqual([
      { id: 9, name: "New Person", unitName: "B" },
    ]);

    // A second successful fetch does not resubscribe.
    await store.refetchHostsSilently();
    expect(window.Comeals.pusher.subscribe).toHaveBeenCalledTimes(1);
  });
});
