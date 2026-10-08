import { describe, it, expect, vi, beforeEach } from "vitest";
import {
  render,
  screen,
  fireEvent,
  cleanup,
  act,
} from "@testing-library/react";
import { MemoryRouter, Routes, Route, useLocation } from "react-router";

vi.mock("axios", () => import("../mocks/axios.js"));

import axios from "axios";
import toastStore from "../../../app/frontend/src/stores/toast_store.js";
import { messagesShown } from "../helpers/form_messages.js";
import ResidentsPasswordNew from "../../../app/frontend/src/components/residents/password_new.jsx";

function LocationEcho() {
  const location = useLocation();
  return <span data-testid="location">{location.pathname}</span>;
}

// The component reads the reset token from the route.
function renderForm() {
  render(
    <MemoryRouter initialEntries={["/reset-password/tok-1/"]}>
      <Routes>
        <Route path="/:modal/:token/*" element={<ResidentsPasswordNew />} />
        <Route path="/" element={<span>login page</span>} />
      </Routes>
      <LocationEcho />
    </MemoryRouter>,
  );
}

function deferred() {
  const d = {};
  d.promise = new Promise(function (resolve, reject) {
    d.resolve = resolve;
    d.reject = reject;
  });
  return d;
}

describe("ResidentsPasswordNew", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    toastStore.clearAll();
  });

  it("shows Loading until the name arrives, then the form", async () => {
    axios.get.mockResolvedValue({ status: 200, data: { name: "Jane Smith" } });
    renderForm();

    expect(screen.getByText("Loading...")).toBeInTheDocument();
    expect(
      await screen.findByText("Reset Password for Jane Smith"),
    ).toBeInTheDocument();
    expect(axios.get).toHaveBeenCalledWith("/api/v1/residents/name/tok-1");
  });

  it("submits the typed password to the token's endpoint", async () => {
    axios.get.mockResolvedValue({ status: 200, data: { name: "Jane Smith" } });
    axios.post.mockResolvedValue({ status: 200, data: {} });
    renderForm();

    const input = await screen.findByPlaceholderText("New Password");
    fireEvent.change(input, { target: { value: "hunter2hunter2" } });
    fireEvent.click(screen.getByRole("button", { name: "Submit" }));

    expect(axios.post).toHaveBeenCalledWith(
      "/api/v1/residents/password-reset/tok-1",
      { password: "hunter2hunter2" },
    );
  });

  it("a saved password shows the answer and returns to the login page", async () => {
    axios.get.mockResolvedValue({ status: 200, data: { name: "Jane Smith" } });
    axios.post.mockResolvedValue({
      status: 200,
      data: { message: "Password updated!" },
    });
    renderForm();

    const input = await screen.findByPlaceholderText("New Password");
    fireEvent.change(input, { target: { value: "hunter2hunter2" } });
    fireEvent.click(screen.getByRole("button", { name: "Submit" }));

    expect(await screen.findByText("login page")).toBeInTheDocument();
    expect(toastStore.toasts.map((t) => t.message)).toEqual([
      "Password updated!",
    ]);
  });

  // The form is in a dialog, and the stack of messages is drawn under
  // an open dialog, so the reason shows inside the form, under its
  // title (#137).
  it("a refused password shows the reason inside the form and frees the form", async () => {
    // What ResidentsController#password_new answers when the resident
    // row itself no longer saves (#105): one line per field, then who
    // can fix it.
    const reason =
      "Your password was not changed:\nName can't be blank\nPlease ask an admin to fix your account.";
    axios.get.mockResolvedValue({ status: 200, data: { name: "Jane Smith" } });
    axios.post.mockRejectedValue({
      response: { status: 400, data: { message: reason } },
    });
    renderForm();

    const input = await screen.findByPlaceholderText("New Password");
    fireEvent.change(input, { target: { value: "x" } });
    fireEvent.click(screen.getByRole("button", { name: "Submit" }));

    await vi.waitFor(() => {
      expect(messagesShown()).toEqual({ form: [reason], stack: [] });
    });
    expect(screen.getByRole("alert")).toHaveTextContent(
      "Your password was not changed:",
    );
    expect(screen.getByRole("button", { name: "Submit" })).toBeEnabled();
  });

  // A try that works closes the dialog, and the reasons earlier tries
  // got go with it.
  it("a password saved after a refusal takes the refusal away with the form", async () => {
    axios.get.mockResolvedValue({ status: 200, data: { name: "Jane Smith" } });
    axios.post.mockRejectedValueOnce({ request: {} });
    axios.post.mockResolvedValueOnce({
      status: 200,
      data: { message: "Password updated!" },
    });
    renderForm();
    const input = await screen.findByPlaceholderText("New Password");
    fireEvent.change(input, { target: { value: "hunter2hunter2" } });
    fireEvent.click(screen.getByRole("button", { name: "Submit" }));
    await vi.waitFor(() => {
      expect(messagesShown().form).toEqual([
        "Error: no response received from server.",
      ]);
    });

    fireEvent.click(screen.getByRole("button", { name: "Submit" }));

    expect(await screen.findByText("login page")).toBeInTheDocument();
    expect(messagesShown()).toEqual({
      form: [],
      stack: ["Password updated!"],
    });
  });

  // The two answers the server gives for a link it will not use
  // (ResidentsController#show_name). The person lands on the login
  // page and is told why there.
  it.each([
    "Password reset link is incorrect or expired.",
    "Password reset link has expired. Please request a new one.",
  ])(
    "a link the server refuses goes to the login page and says: %s",
    async (message) => {
      axios.get.mockRejectedValue({
        response: { status: 400, data: { message: message } },
      });
      renderForm();
      expect(await screen.findByText("login page")).toBeInTheDocument();
      expect(
        toastStore.toasts.map((t) => ({ message: t.message, type: t.type })),
      ).toEqual([{ message: message, type: "error" }]);
    },
  );

  // With no answer from the server there is nothing to go on, so the
  // page stays and says so, instead of "Loading..." forever.
  it.each([
    // What axios rejects with when no answer came back.
    ["a network failure", { request: {}, message: "Network Error" }],
    // A throw before any request was sent.
    ["an error before the request", new Error("boom")],
  ])("%s on the name lookup says so and stays", async (_name, error) => {
    axios.get.mockRejectedValue(error);
    renderForm();
    expect(
      await screen.findByText(
        "Could not load this page. Check your connection and try again.",
      ),
    ).toBeVisible();
    expect(screen.queryByText("Loading...")).not.toBeInTheDocument();
    expect(
      screen.queryByPlaceholderText("New Password"),
    ).not.toBeInTheDocument();
    expect(screen.getByTestId("location")).toHaveTextContent(
      "/reset-password/tok-1/",
    );
    expect(toastStore.toasts).toHaveLength(0);
  });

  // React shows no sign when it drops a state update on a page that is
  // gone, so this only checks that a late name does not throw.
  it("a name that arrives after the page is gone throws nothing", async () => {
    const name = deferred();
    axios.get.mockReturnValueOnce(name.promise);
    renderForm();
    cleanup();
    await act(async () => name.resolve({ status: 200, data: { name: "J" } }));
    expect(document.body).not.toHaveTextContent("Reset Password");
  });

  it("a refusal that arrives after the page is gone shows nothing", async () => {
    const refusedName = deferred();
    axios.get.mockReturnValueOnce(refusedName.promise);
    renderForm();
    cleanup();
    await act(async () =>
      refusedName.reject({
        response: {
          status: 400,
          data: { message: "Password reset link is incorrect or expired." },
        },
      }),
    );
    expect(toastStore.toasts).toHaveLength(0);
  });

  it("a save answered after the page is gone shows nothing", async () => {
    axios.get.mockResolvedValue({ status: 200, data: { name: "Jane Smith" } });
    for (const settle of ["resolve", "reject"]) {
      const save = deferred();
      axios.post.mockReturnValueOnce(save.promise);
      renderForm();
      const input = await screen.findByPlaceholderText("New Password");
      fireEvent.change(input, { target: { value: "hunter2hunter2" } });
      fireEvent.click(screen.getByRole("button", { name: "Submit" }));
      cleanup();
      await act(async () =>
        save[settle]({ status: 200, data: { message: "Late." } }),
      );
    }
    expect(toastStore.toasts).toHaveLength(0);
  });
});
