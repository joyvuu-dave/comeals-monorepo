import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";

// The Idempotency-Key of a guest add (S2). A guest add whose answer is
// lost may have been written, and the page shows no guest then, so the
// person taps again. That tap sends the lost add's key, so the server
// adds the guest at most once and the host pays once. Mock external
// modules before importing stores.
vi.mock("axios", () => import("../mocks/axios.js"));

vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));

vi.mock("pusher-js", () => import("../mocks/pusher.js"));

vi.mock("idb-keyval", () => import("../mocks/idb_keyval.js"));

vi.mock("../../../app/frontend/src/helpers/bugsnag.js", () => ({
  notifyError: vi.fn(),
}));

import axios from "axios";
import {
  createDataStore,
  stage,
  stubAction,
} from "../helpers/create_data_store.js";
import { deadConnection } from "../helpers/dead_connection.js";
import toastStore from "../../../app/frontend/src/stores/toast_store.js";
import { notifyError } from "../../../app/frontend/src/helpers/bugsnag.js";

const NO_ANSWER = { request: {} };
const KEY_FORMAT =
  /^"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"$/;

// What the server answers for a guest it added (GuestSerializer).
function added(id, host = 10, vegetarian = false) {
  return {
    status: 200,
    data: {
      id,
      meal_id: 1,
      resident_id: host,
      vegetarian,
      created_at: "2023-06-15T18:30:00.000Z",
    },
  };
}

// What the server answers for a key it has seen (GuestReplayedSerializer).
function replayed(guest) {
  return {
    status: 200,
    data: {
      message: "This guest was already added, so nothing more was added.",
      type: "replayed",
      guest: guest === null ? null : added(guest).data,
    },
  };
}

let loadDataAsyncSpy;

// A closed meal with three seats left, so each guest's seat shows. Alice
// and Bob are signed up, and Alice already has guest 100.
function store() {
  const s = createDataStore({
    mealProps: {
      closed: true,
      closed_at: new Date(2023, 0, 1).getTime(),
      extras: 3,
      date: new Date(2023, 5, 15),
    },
    residents: [
      {
        id: 10,
        meal_id: 1,
        name: "A - Alice",
        short_name: "Alice",
        attending: true,
      },
      {
        id: 11,
        meal_id: 1,
        name: "B - Bob",
        short_name: "Bob",
        attending: true,
      },
    ],
    guests: [
      {
        id: 100,
        meal_id: 1,
        resident_id: 10,
        created_at: new Date(2023, 0, 1, 13).getTime(),
      },
    ],
  });
  loadDataAsyncSpy = stubAction(s, "loadDataAsync");
  window.Comeals.socketId = "test";
  return s;
}

// The Idempotency-Key of each guest add sent so far, in order.
function keysSent() {
  return axios.mock.calls
    .map(([config]) => config)
    .filter((config) => config.url.endsWith("/guests"))
    .map((config) => config.headers["Idempotency-Key"]);
}

function addFor(s, id, vegetarian = false) {
  s.residents.get(String(id)).addGuest({ vegetarian });
}

async function settle() {
  await new Promise((r) => setTimeout(r, 0));
}

describe("a guest add's Idempotency-Key", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    toastStore.clearAll();
    window.Comeals = {
      socketId: "test",
      pusher: null,
      mealChannel: null,
      calendarChannel: null,
    };
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("goes with each guest add, a new one each time", async () => {
    const s = store();
    axios.mockResolvedValueOnce(added(555)).mockResolvedValueOnce(added(556));

    addFor(s, 10);
    await settle();
    addFor(s, 10);
    await settle();

    expect(axios).toHaveBeenCalledWith({
      method: "post",
      url: "/api/v1/meals/1/residents/10/guests",
      withCredentials: true,
      timeout: 35000,
      headers: { "Idempotency-Key": expect.stringMatching(KEY_FORMAT) },
      data: { vegetarian: false, socket_id: "test" },
    });
    const [first, second] = keysSent();
    expect(second).not.toBe(first);
    expect(s.residents.get("10").guestsCount).toBe(3);
  });

  // The case the key is for.
  it("goes again with the next tap after an add got no answer", async () => {
    const s = store();
    axios.mockRejectedValueOnce(NO_ANSWER);

    addFor(s, 10);
    await settle();
    axios.mockResolvedValueOnce(replayed(555));
    addFor(s, 10);
    await settle();

    const [first, second] = keysSent();
    expect(second).toBe(first);
  });

  // The phone's connection dropped after the server wrote the guest.
  // The browser can wait for minutes, and all that time the page shows
  // no guest and no message, so the person taps again. The add stops
  // waiting after 35 seconds, so the meal loads again, and the next tap
  // sends the same key and adds nothing more.
  it("goes again with the next tap after an add on a dead connection stops waiting", async () => {
    vi.useFakeTimers();
    const s = store();
    axios.mockImplementationOnce(deadConnection);

    addFor(s, 10);
    await vi.advanceTimersByTimeAsync(35000);
    expect(loadDataAsyncSpy).toHaveBeenCalledTimes(1);

    axios.mockResolvedValueOnce(replayed(555));
    addFor(s, 10);
    await vi.advanceTimersByTimeAsync(0);

    const [first, second] = keysSent();
    expect(second).toBe(first);
    expect(s.guests.has("555")).toBe(true);
    expect(s.residents.get("10").guestsCount).toBe(2);
  });

  // Each tap after no answer takes one lost add's key, so the tap after
  // that one is a new add.
  it("goes again with one tap only: the tap after it gets a new key", async () => {
    const s = store();
    axios.mockRejectedValueOnce(NO_ANSWER);
    addFor(s, 10);
    await settle();

    axios
      .mockResolvedValueOnce(replayed(555))
      .mockResolvedValueOnce(added(556));
    addFor(s, 10);
    await settle();
    addFor(s, 10);
    await settle();

    const [first, second, third] = keysSent();
    expect(second).toBe(first);
    expect(third).not.toBe(first);
  });

  // The key goes again only with an add that asks for the same guest:
  // the same meal, the same host, and the same veg choice. Any other add
  // is another guest.
  it("goes again only for the same host and the same veg choice", async () => {
    const s = store();
    axios.mockRejectedValueOnce(NO_ANSWER);
    addFor(s, 10, false);
    await settle();

    axios
      .mockResolvedValueOnce(added(556, 10, true))
      .mockResolvedValueOnce(added(557, 11));
    addFor(s, 10, true);
    addFor(s, 11, false);
    await settle();

    const [lost, vegGuest, bobsGuest] = keysSent();
    expect(vegGuest).not.toBe(lost);
    expect(bobsGuest).not.toBe(lost);
  });

  // The same key with no answer again stays for the tap after that.
  it("stays for the next tap while the add it goes with gets no answer", async () => {
    const s = store();
    axios.mockRejectedValueOnce(NO_ANSWER).mockRejectedValueOnce(NO_ANSWER);
    addFor(s, 10);
    await settle();
    addFor(s, 10);
    await settle();

    axios.mockResolvedValueOnce(replayed(555));
    addFor(s, 10);
    await settle();

    expect(new Set(keysSent()).size).toBe(1);
  });

  // Any answer from the app says what happened to the add, so its key
  // is done: a refused add wrote nothing, and the next tap is a new add.
  it("is done once the app answers the add that carried it", async () => {
    const s = store();
    axios.mockRejectedValueOnce(NO_ANSWER).mockRejectedValueOnce({
      response: { status: 400, data: { message: "Meal has no open spots." } },
    });
    addFor(s, 10);
    await settle();
    addFor(s, 10);
    await settle();

    axios.mockResolvedValueOnce(added(556));
    addFor(s, 10);
    await settle();

    const [first, second, third] = keysSent();
    expect(second).toBe(first);
    expect(third).not.toBe(first);
  });

  describe("when the server answers that the guest was already added", () => {
    // The lost add was written, and the page never showed its guest. So
    // the tap was for that guest: it shows, and nothing more is sent.
    it("shows that guest, and takes its seat", async () => {
      const s = store();
      axios.mockRejectedValueOnce(NO_ANSWER);
      addFor(s, 10);
      await settle();
      expect(s.meal.extras).toBe(3);

      axios.mockResolvedValueOnce(replayed(555));
      addFor(s, 10);
      await settle();

      expect(keysSent()).toHaveLength(2);
      expect(s.guests.has("555")).toBe(true);
      expect(s.residents.get("10").guestsCount).toBe(2);
      expect(s.meal.extras).toBe(2);
      expect(s.guests.get("555").created_at).toEqual(
        new Date("2023-06-15T18:30:00.000Z"),
      );
    });

    // The meal loaded again after the lost add, and showed its guest. A
    // tap after that is for one more guest, so a new add goes out, with
    // a new key.
    it("adds one more guest with a new key when that guest was already on screen at the tap", async () => {
      const s = store();
      axios.mockRejectedValueOnce(NO_ANSWER);
      addFor(s, 10);
      await settle();
      // The meal loaded again and showed the lost add's guest, 555.
      stage(s, () => {
        s.guests.put({
          id: 555,
          meal_id: 1,
          resident_id: 10,
          created_at: new Date(2023, 0, 1, 14).getTime(),
        });
      });
      // The rows were not built again here, so the seat count is the
      // one the page had; a real load would have set it.

      axios
        .mockResolvedValueOnce(replayed(555))
        .mockResolvedValueOnce(added(556));
      addFor(s, 10);
      await settle();

      const [lost, again, oneMore] = keysSent();
      expect(again).toBe(lost);
      expect(oneMore).not.toBe(lost);
      expect(s.guests.has("556")).toBe(true);
      expect(s.residents.get("10").guestsCount).toBe(3);
    });

    // Someone removed the lost add's guest. The tap was for a guest, so
    // a new add goes out, with a new key.
    it("adds a new guest with a new key when that guest was removed since", async () => {
      const s = store();
      axios.mockRejectedValueOnce(NO_ANSWER);
      addFor(s, 10);
      await settle();

      axios
        .mockResolvedValueOnce(replayed(null))
        .mockResolvedValueOnce(added(556));
      addFor(s, 10);
      await settle();

      const [lost, again, newAdd] = keysSent();
      expect(again).toBe(lost);
      expect(newAdd).not.toBe(lost);
      expect(s.guests.has("556")).toBe(true);
      expect(s.meal.extras).toBe(2);
    });

    // Two adds were lost. The tap after them for one more guest tries
    // the second lost add before a new one: if it was written, its guest
    // is the one more. Since S4 a host's add-guest control takes no taps
    // while an add of theirs waits, so the screen cannot have two adds
    // for one host out at once, and this list holds one key at most.
    // The list still keeps every lost key in order, so the two adds go
    // to the store's send directly here.
    it("tries the next lost add's key before a new one", async () => {
      const s = store();
      axios.mockRejectedValueOnce(NO_ANSWER).mockRejectedValueOnce(NO_ANSWER);
      const alice = s.residents.get("10");
      for (let i = 0; i < 2; i += 1) {
        s.sendGuestAdd({
          row: alice,
          mealId: 1,
          hostId: 10,
          vegetarian: false,
          tapped: { name: "Alice", mealId: 1, mealDay: "Thu, Jun 15th" },
          guestIdsAtTap: [100],
        });
      }
      await settle();
      stage(s, () => {
        s.guests.put({
          id: 555,
          meal_id: 1,
          resident_id: 10,
          created_at: new Date(2023, 0, 1, 14).getTime(),
        });
      });

      axios
        .mockResolvedValueOnce(replayed(555))
        .mockResolvedValueOnce(replayed(556));
      addFor(s, 10);
      await settle();

      const [lostOne, lostTwo, again, next] = keysSent();
      expect([again, next]).toEqual([lostOne, lostTwo]);
      expect(keysSent()).toHaveLength(4);
      expect(s.guests.has("556")).toBe(true);
    });

    // The meal loaded again while the add was out, so the row is not the
    // one that was tapped. That load may have been read before the
    // guest was written, so the guest shows now, with its seat, and the
    // page loads once more to show what else the server has (S4).
    it("shows the guest and loads the meal again when the row was built again while the add was out", async () => {
      const s = store();
      axios.mockRejectedValueOnce(NO_ANSWER);
      addFor(s, 10);
      await settle();
      loadDataAsyncSpy.mockClear();
      toastStore.clearAll();

      let answer;
      axios.mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            answer = resolve;
          }),
      );
      addFor(s, 10);
      stage(s, () => {
        s.residents.clear();
        s.residents.put({
          id: 10,
          meal_id: 1,
          name: "A - Alice",
          attending: true,
        });
      });
      answer(replayed(555));
      await settle();

      expect(loadDataAsyncSpy).toHaveBeenCalledTimes(1);
      expect(s.guests.has("555")).toBe(true);
      expect(s.meal.extras).toBe(2);
      expect(toastStore.toasts).toHaveLength(0);
    });
  });

  // A key sent again with another guest's add is a bug in the page.
  it("reports a 422 as a bug, and shows the server's words", async () => {
    const s = store();
    axios.mockRejectedValueOnce({
      response: {
        status: 422,
        data: {
          message:
            "This Idempotency-Key was already used for a different guest add. Nothing was saved. Send a new key with each guest add.",
        },
      },
    });

    addFor(s, 10);
    await settle();

    expect(notifyError).toHaveBeenCalledWith(
      new Error(
        "The server refused a guest add for meal 1: its Idempotency-Key was already used for a different guest add",
      ),
    );
    expect(toastStore.toasts.map((t) => t.message)).toEqual([
      "Alice: This Idempotency-Key was already used for a different guest add. Nothing was saved. Send a new key with each guest add.",
    ]);
    expect(s.meal.extras).toBe(3);
  });
});
