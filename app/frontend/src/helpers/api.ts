// Typed wrappers around the bare `axios({...})` calls scattered through the
// stores. See docs/adr/0001-typescript-at-the-api-boundary.md.
//
// Design rules:
//   - Reuse the global `axios` import. Do NOT create a new instance — the
//     response interceptor in data_store.js handles 401s for the whole app
//     and only attaches to the default instance.
//   - Return `Promise<AxiosResponse<T>>`, not `Promise<T>`. Existing consumers
//     check `response.status` and can be migrated piecemeal.
//   - `withCredentials: true` is preserved on mutations to match prior
//     behavior; GETs do not set it.

import axios, { AxiosResponse } from "axios";

import { Ack, BillsAck, Guest, MealForm, MealResident } from "../types/api";

// One side of a bills edit: a cook's bill as the page saw it (`from`),
// or as the person wants it (`to`). The amount is text, never a number
// (ADR 0001): "" is 0, and the server refuses a JSON number.
export interface BillValues {
  amount: string;
  no_cost: boolean;
}

// One edit in a bills save (#135, docs/adr/0009-bills-saves-send-edits.md).
// It names one cook. A change or a remove carries the bill the page saw
// for that cook, and the server writes nothing if the stored bill is no
// longer that. A cook no edit names is never touched.
export type BillEdit =
  | { op: "add"; resident_id: number; to: BillValues }
  | { op: "change"; resident_id: number; from: BillValues; to: BillValues }
  | { op: "remove"; resident_id: number; from: BillValues };

// How long the page waits for the answer to a bills save. Heroku's
// router ends a request at 30 seconds, so a request still open after 35
// seconds lost its answer on the way (a dropped connection can leave
// the browser waiting for minutes). Until a save is answered, no other
// bills save is sent and its meal is not loaded again, so the wait must
// end.
export const BILLS_SAVE_TIMEOUT_MS = 35000;

interface SocketBound {
  socketId: string | null;
}

export const api = {
  meals: {
    getCooks(mealId: number): Promise<AxiosResponse<MealForm>> {
      return axios.get<MealForm>(`/api/v1/meals/${mealId}/cooks`);
    },

    updateClosed(
      mealId: number,
      { closed, socketId }: { closed: boolean } & SocketBound,
    ): Promise<AxiosResponse<Ack>> {
      return axios({
        method: "patch",
        url: `/api/v1/meals/${mealId}/closed`,
        withCredentials: true,
        data: { closed, socket_id: socketId },
      });
    },

    updateDescription(
      mealId: number,
      { description, socketId }: { description: string } & SocketBound,
    ): Promise<AxiosResponse<Ack>> {
      return axios({
        method: "patch",
        url: `/api/v1/meals/${mealId}/description`,
        withCredentials: true,
        data: { id: mealId, description, socket_id: socketId },
      });
    },

    // `key` is the save's Idempotency-Key (IETF draft "The
    // Idempotency-Key HTTP Header Field"): a new one for each save, and
    // the same one when that save is sent again. The header's value is a
    // quoted string (RFC 9651). The keys are UUIDs, which have no quote
    // or backslash to escape.
    updateBills(
      mealId: number,
      {
        edits,
        key,
        socketId,
      }: { edits: BillEdit[]; key: string } & SocketBound,
    ): Promise<AxiosResponse<BillsAck>> {
      return axios({
        method: "patch",
        url: `/api/v1/meals/${mealId}/bills`,
        withCredentials: true,
        timeout: BILLS_SAVE_TIMEOUT_MS,
        headers: { "Idempotency-Key": `"${key}"` },
        data: { edits, socket_id: socketId },
      });
    },

    updateMax(
      mealId: number,
      { max, socketId }: { max: number | null } & SocketBound,
    ): Promise<AxiosResponse<Ack>> {
      return axios({
        method: "patch",
        url: `/api/v1/meals/${mealId}/max`,
        withCredentials: true,
        data: { max, socket_id: socketId },
      });
    },

    residents: {
      add(
        mealId: number,
        residentId: number,
        {
          late,
          vegetarian,
          socketId,
        }: { late: boolean; vegetarian: boolean } & SocketBound,
      ): Promise<AxiosResponse<MealResident>> {
        return axios({
          method: "post",
          url: `/api/v1/meals/${mealId}/residents/${residentId}`,
          withCredentials: true,
          data: { late, vegetarian, socket_id: socketId },
        });
      },

      remove(
        mealId: number,
        residentId: number,
        { socketId }: SocketBound,
      ): Promise<AxiosResponse<Ack>> {
        return axios({
          method: "delete",
          url: `/api/v1/meals/${mealId}/residents/${residentId}`,
          withCredentials: true,
          data: { socket_id: socketId },
        });
      },

      // Used for both toggleLate and toggleVeg — the endpoint accepts a partial
      // patch of either flag.
      update(
        mealId: number,
        residentId: number,
        patch: ({ late: boolean } | { vegetarian: boolean }) & SocketBound,
      ): Promise<AxiosResponse<Ack>> {
        const { socketId, ...rest } = patch;
        return axios({
          method: "patch",
          url: `/api/v1/meals/${mealId}/residents/${residentId}`,
          withCredentials: true,
          data: { ...rest, socket_id: socketId },
        });
      },

      guests: {
        add(
          mealId: number,
          residentId: number,
          { vegetarian, socketId }: { vegetarian: boolean } & SocketBound,
        ): Promise<AxiosResponse<Guest>> {
          return axios({
            method: "post",
            url: `/api/v1/meals/${mealId}/residents/${residentId}/guests`,
            withCredentials: true,
            data: { vegetarian, socket_id: socketId },
          });
        },

        remove(
          mealId: number,
          residentId: number,
          guestId: number,
          { socketId }: SocketBound,
        ): Promise<AxiosResponse<Ack>> {
          return axios({
            method: "delete",
            url: `/api/v1/meals/${mealId}/residents/${residentId}/guests/${guestId}`,
            withCredentials: true,
            data: { socket_id: socketId },
          });
        },
      },
    },
  },
};
