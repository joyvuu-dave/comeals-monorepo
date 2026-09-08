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

  it("a refused password shows the reason and frees the form", async () => {
    axios.get.mockResolvedValue({ status: 200, data: { name: "Jane Smith" } });
    axios.post.mockRejectedValue({
      response: { status: 400, data: { message: "Invalid password." } },
    });
    renderForm();

    const input = await screen.findByPlaceholderText("New Password");
    fireEvent.change(input, { target: { value: "x" } });
    fireEvent.click(screen.getByRole("button", { name: "Submit" }));

    await vi.waitFor(() => {
      expect(toastStore.toasts.map((t) => t.message)).toEqual([
        "Invalid password.",
      ]);
    });
    expect(screen.getByRole("button", { name: "Submit" })).toBeEnabled();
  });

  it("a bad or expired link goes back to the login page", async () => {
    axios.get.mockRejectedValue({
      response: {
        status: 400,
        data: { message: "Password reset link is incorrect or expired." },
      },
    });
    renderForm();
    expect(await screen.findByText("login page")).toBeInTheDocument();
  });

  it("a network failure on the name lookup keeps Loading", async () => {
    axios.get.mockRejectedValue(new Error("Network Error"));
    renderForm();
    await act(async () => {});
    expect(screen.getByText("Loading...")).toBeInTheDocument();
    expect(screen.getByTestId("location")).toHaveTextContent(
      "/reset-password/tok-1/",
    );
  });

  it("answers that land after the form is gone touch nothing", async () => {
    // The name lookup, resolved late.
    const name = deferred();
    axios.get.mockReturnValueOnce(name.promise);
    renderForm();
    cleanup();
    await act(async () => name.resolve({ status: 200, data: { name: "J" } }));
    expect(document.body).not.toHaveTextContent("Reset Password");

    // The name lookup, refused late.
    const refusedName = deferred();
    axios.get.mockReturnValueOnce(refusedName.promise);
    renderForm();
    cleanup();
    await act(async () =>
      refusedName.reject({ response: { status: 400, data: {} } }),
    );

    // The password save, resolved late and refused late.
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
