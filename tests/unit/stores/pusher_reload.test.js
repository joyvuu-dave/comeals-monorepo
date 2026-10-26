import { describe, it, expect, vi } from "vitest";

// The store starts the Pusher client. If the library fails to load, the
// page reloads once (pusher_client.js), and the reload ends every bills
// save on its way. So the store hands startPusher the step that sends
// each one again with keepalive first (#150). The reload itself is
// tested in tests/unit/helpers/pusher_client.test.js.

vi.mock("axios", () => import("../mocks/axios.js"));
vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));
vi.mock("idb-keyval", () => import("../mocks/idb_keyval.js"));
vi.mock("../../../app/frontend/src/helpers/pusher_client.js", async () => {
  const real = await vi.importActual(
    "../../../app/frontend/src/helpers/pusher_client.js",
  );
  return { ...real, startPusher: vi.fn() };
});

import { stubRandomUUID } from "../mocks/uuid.js";
stubRandomUUID();

import { destroy } from "mobx-state-tree";
import { startPusher } from "../../../app/frontend/src/helpers/pusher_client.js";
import { createDataStore, stubAction } from "../helpers/create_data_store.js";

describe("the store's start of the Pusher client", () => {
  it("sends the bills saves again before a reload for a failed library load", () => {
    const store = createDataStore();
    const sendAgain = stubAction(store, "sendBillsAgainBeforeClose");

    expect(startPusher).toHaveBeenCalledTimes(1);
    const beforeReload = startPusher.mock.calls[0][0];
    expect(sendAgain).not.toHaveBeenCalled();

    beforeReload();

    expect(sendAgain).toHaveBeenCalledTimes(1);
    destroy(store);
  });
});
