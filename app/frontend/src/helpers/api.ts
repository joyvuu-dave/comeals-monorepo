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

// One row of the bills payload. Every cook appears (the server deletes
// bills for cooks left out), but amount/no_cost are only present for rows
// the user touched — the server leaves the other rows' stored values alone.
export interface BillInput {
  resident_id: number;
  amount?: string;
  no_cost?: boolean;
}

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

    updateBills(
      mealId: number,
      { bills, socketId }: { bills: BillInput[] } & SocketBound,
    ): Promise<AxiosResponse<BillsAck>> {
      return axios({
        method: "patch",
        url: `/api/v1/meals/${mealId}/bills`,
        withCredentials: true,
        data: { id: mealId, bills, socket_id: socketId },
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
