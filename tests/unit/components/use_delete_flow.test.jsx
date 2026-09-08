import { describe, it, expect, vi, beforeEach } from "vitest";
import { renderHook, act } from "@testing-library/react";

vi.mock("axios", () => import("../mocks/axios.js"));
vi.mock("../../../app/frontend/src/helpers/handle_axios_error.js", () => ({
  default: vi.fn(),
}));

import axios from "axios";
import handleAxiosError from "../../../app/frontend/src/helpers/handle_axios_error.js";
import useDeleteFlow from "../../../app/frontend/src/components/modal_form/use_delete_flow.js";

// The edit modals drive the whole flow through their Delete buttons
// (events_edit.test.jsx and the reservation edit tests). These are the
// paths a modal cannot reach on purpose: a click during another save,
// and an answer that lands after the modal is gone.
function renderFlow(overrides = {}) {
  const props = {
    url: "/api/v1/events/7",
    message: "Delete this event?",
    loadingAction: null,
    setLoadingAction: vi.fn(),
    mountedRef: { current: true },
    onDeleted: vi.fn(),
    ...overrides,
  };
  const hook = renderHook(() => useDeleteFlow(props));
  return { props, hook };
}

describe("useDeleteFlow", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("Delete opens the confirm, and a confirmed delete sends the request", async () => {
    const { props, hook } = renderFlow();
    expect(hook.result.current.confirmProps.isOpen).toBe(false);

    act(() => hook.result.current.requestDelete());
    expect(hook.result.current.confirmProps.isOpen).toBe(true);

    await act(async () => hook.result.current.confirmProps.onConfirm());
    expect(axios.delete).toHaveBeenCalledWith("/api/v1/events/7");
    expect(props.setLoadingAction).toHaveBeenCalledWith("delete");
    expect(props.setLoadingAction).toHaveBeenLastCalledWith(null);
    expect(props.onDeleted).toHaveBeenCalledTimes(1);
    expect(hook.result.current.confirmProps.isOpen).toBe(false);
  });

  it("Cancel closes the confirm without a request", () => {
    const { hook } = renderFlow();
    act(() => hook.result.current.requestDelete());
    act(() => hook.result.current.confirmProps.onCancel());
    expect(hook.result.current.confirmProps.isOpen).toBe(false);
    expect(axios.delete).not.toHaveBeenCalled();
  });

  it("ignores Delete while another action is saving", () => {
    const { hook } = renderFlow({ loadingAction: "update" });
    act(() => hook.result.current.requestDelete());
    expect(hook.result.current.confirmProps.isOpen).toBe(false);
  });

  it("a failed delete clears the loading state and reports the error", async () => {
    const error = { response: { status: 400, data: { message: "No." } } };
    axios.delete.mockRejectedValueOnce(error);
    const { props, hook } = renderFlow();

    await act(async () => hook.result.current.confirmProps.onConfirm());
    expect(props.setLoadingAction).toHaveBeenLastCalledWith(null);
    expect(handleAxiosError).toHaveBeenCalledWith(error);
    expect(props.onDeleted).not.toHaveBeenCalled();
  });

  it("does nothing with an answer that lands after the modal is gone", async () => {
    const mountedRef = { current: true };
    const { props, hook } = renderFlow({ mountedRef });

    let deliver;
    axios.delete.mockReturnValueOnce(
      new Promise(function (resolve) {
        deliver = resolve;
      }),
    );
    await act(async () => hook.result.current.confirmProps.onConfirm());
    mountedRef.current = false;
    await act(async () => deliver({ status: 200, data: {} }));
    expect(props.setLoadingAction).toHaveBeenCalledTimes(1);
    expect(props.onDeleted).not.toHaveBeenCalled();

    let fail;
    mountedRef.current = true;
    axios.delete.mockReturnValueOnce(
      new Promise(function (resolve, reject) {
        fail = reject;
      }),
    );
    await act(async () => hook.result.current.confirmProps.onConfirm());
    mountedRef.current = false;
    await act(async () => fail({ response: { status: 500, data: {} } }));
    expect(handleAxiosError).not.toHaveBeenCalled();
  });
});
