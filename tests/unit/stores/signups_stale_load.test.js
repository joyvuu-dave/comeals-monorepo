import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";

// A load of the meal is out when a request from the sign-up list is
// answered. The server may have read the meal before it wrote that
// request, and then the load's answer does not have it. The push for
// the request skips this screen, because the request carried this
// screen's socket id, so nothing would put the change back on the
// screen. A person who sees their guest go away taps again, and the
// host pays for two guests. So an answer to a load that went out before
// a request from the sign-up list was answered is not used, and the
// meal loads again. The same rule as for bills edits (#136). Mock
// external modules before importing stores.
vi.mock("axios", () => import("../mocks/axios.js"));

vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));

vi.mock("pusher-js", () => import("../mocks/pusher.js"));

vi.mock("idb-keyval", () => import("../mocks/idb_keyval.js"));

vi.mock("../../../app/frontend/src/helpers/bugsnag.js", () => ({
  notifyError: vi.fn(),
}));

import axios from "axios";
import * as idbKeyval from "idb-keyval";
import { createDataStore } from "../helpers/create_data_store.js";
import toastStore from "../../../app/frontend/src/stores/toast_store.js";

const ALICE = {
  id: 10,
  meal_id: 1,
  name: "A - Alice Smith",
  short_name: "Alice Smith",
  attending: true,
  attending_at: "2023-06-15T20:00:00.000Z",
  late: false,
  vegetarian: false,
  can_cook: true,
  active: true,
};
const CAROL = {
  ...ALICE,
  id: 12,
  name: "C - Carol Diaz",
  short_name: "Carol Diaz",
  attending: false,
  attending_at: null,
};

// The meal as the server sends it (MealFormSerializer): closed, cap 5,
// Alice signed up with her guests, and Carol not signed up unless the
// test says so. With guest 100 only, Total is 2 and Extras is 3.
function mealForm({ guests = [100], carol = CAROL } = {}) {
  return {
    id: 1,
    date: "2023-06-15",
    description: "",
    closed: true,
    closed_at: "2023-06-15T12:00:00.000Z",
    reconciled: false,
    max: 5,
    next_id: null,
    prev_id: null,
    residents: [ALICE, carol],
    guests: guests.map((id) => ({
      id,
      meal_id: 1,
      resident_id: 10,
      vegetarian: false,
      created_at: "2023-06-15T20:00:00.000Z",
    })),
    bills: [],
  };
}

// What the server answers for a guest it added (GuestSerializer).
function added(id) {
  return {
    status: 200,
    data: {
      id,
      meal_id: 1,
      resident_id: 10,
      vegetarian: false,
      created_at: "2023-06-15T21:00:00.000Z",
    },
  };
}

// The next call to `mock` waits until the test answers it.
function answerLater(mock) {
  let answer;
  mock.mockImplementationOnce(
    () =>
      new Promise((resolve) => {
        answer = resolve;
      }),
  );
  return (response) => answer(response);
}

async function settle() {
  for (let i = 0; i < 5; i += 1) {
    await new Promise((r) => setTimeout(r, 0));
  }
}

function loaded() {
  const store = createDataStore({
    mealProps: { id: 1, date: new Date(2023, 5, 15) },
  });
  store.loadData(mealForm(), "server");
  window.Comeals.socketId = "test";
  return store;
}

function shown(store) {
  return {
    extras: store.meal.extras,
    total: store.attendeesCount,
    guests: store.residents.get("10").guestsCount,
  };
}

describe("a meal load that went out before a sign-up request was answered", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    toastStore.clearAll();
  });

  // The shared mocks keep what a test set for them.
  afterEach(() => {
    [axios, axios.get, idbKeyval.set].forEach((mock) => mock.mockReset());
  });

  // The case the S4 review found (#156). A push from another phone
  // starts a load. Alice's guest add is answered. Then the load lands,
  // with a read made before her guest was written.
  it("does not take an added guest off the screen, and the meal loads again", async () => {
    const store = loaded();
    const answerLoad = answerLater(axios.get);
    store.loadDataAsync();
    const answerAdd = answerLater(axios);
    store.residents.get("10").addGuest({ vegetarian: false });

    answerAdd(added(555));
    await settle();
    expect(shown(store)).toEqual({ extras: 2, total: 3, guests: 2 });

    axios.get.mockResolvedValueOnce({
      status: 200,
      data: mealForm({ guests: [100, 555] }),
    });
    answerLoad({ status: 200, data: mealForm() });
    await settle();

    expect(shown(store)).toEqual({ extras: 2, total: 3, guests: 2 });
    expect(axios.get).toHaveBeenCalledTimes(2);
    // The answer that was not used is not saved on the device either.
    expect(idbKeyval.set).toHaveBeenCalledTimes(1);
    expect(idbKeyval.set.mock.calls[0][1].guests).toHaveLength(2);
  });

  it("does not take a sign-up off the screen", async () => {
    const store = loaded();
    const answerLoad = answerLater(axios.get);
    store.loadDataAsync();
    const answerSignUp = answerLater(axios);
    store.residents.get("12").toggleAttending();

    answerSignUp({
      status: 200,
      data: { id: 900, created_at: "2023-06-15T21:00:00.000Z" },
    });
    await settle();
    axios.get.mockResolvedValueOnce({
      status: 200,
      data: mealForm({
        carol: {
          ...CAROL,
          attending: true,
          attending_at: "2023-06-15T21:00:00.000Z",
        },
      }),
    });
    answerLoad({ status: 200, data: mealForm() });
    await settle();

    expect(store.residents.get("12").attending).toBe(true);
    expect(store.meal.extras).toBe(2);
    expect(axios.get).toHaveBeenCalledTimes(2);
  });

  // The answer came while the load's answer was being saved on the
  // device, after the first check.
  it("does not use the load when the answer comes while its copy is saved on the device", async () => {
    const store = loaded();
    const answerLoad = answerLater(axios.get);
    store.loadDataAsync();
    const answerAdd = answerLater(axios);
    store.residents.get("10").addGuest({ vegetarian: false });
    const copySaved = answerLater(idbKeyval.set);

    answerLoad({ status: 200, data: mealForm() });
    await settle();
    answerAdd(added(555));
    await settle();
    axios.get.mockResolvedValueOnce({
      status: 200,
      data: mealForm({ guests: [100, 555] }),
    });
    copySaved();
    await settle();

    expect(shown(store)).toEqual({ extras: 2, total: 3, guests: 2 });
    expect(axios.get).toHaveBeenCalledTimes(2);
  });

  // The load that a request with no answer starts goes out while the
  // page handles that answer. It went out after the answer, so it is
  // used, and the meal is not fetched twice.
  it("uses the load that a request with no answer starts", async () => {
    const store = loaded();
    axios.mockRejectedValueOnce({ request: {} });
    const answerLoad = answerLater(axios.get);

    store.residents.get("10").addGuest({ vegetarian: false });
    await settle();
    answerLoad({ status: 200, data: mealForm({ guests: [100, 555] }) });
    await settle();

    expect(shown(store)).toEqual({ extras: 2, total: 3, guests: 2 });
    expect(axios.get).toHaveBeenCalledTimes(1);
    expect(store.meal.extrasLocked).toBe(false);
  });

  // The same for the load a yes for a row built again starts.
  it("uses the load that a yes for a row built again starts", async () => {
    const store = loaded();
    const answerAdd = answerLater(axios);
    store.residents.get("10").addGuest({ vegetarian: false });
    store.loadData(mealForm(), "server");
    const answerLoad = answerLater(axios.get);

    answerAdd(added(555));
    await settle();
    answerLoad({ status: 200, data: mealForm({ guests: [100, 555] }) });
    await settle();

    expect(shown(store)).toEqual({ extras: 2, total: 3, guests: 2 });
    expect(axios.get).toHaveBeenCalledTimes(1);
    expect(store.meal.extrasLocked).toBe(false);
  });

  // A load that went out after the answer read the meal after the write.
  it("uses a load that went out after the answer", async () => {
    const store = loaded();
    axios.mockResolvedValueOnce(added(555));
    store.residents.get("10").addGuest({ vegetarian: false });
    await settle();

    axios.get.mockResolvedValueOnce({
      status: 200,
      data: mealForm({ guests: [100, 555, 556] }),
    });
    store.loadDataAsync();
    await settle();

    expect(shown(store)).toEqual({ extras: 1, total: 4, guests: 3 });
    expect(axios.get).toHaveBeenCalledTimes(1);
  });
});
