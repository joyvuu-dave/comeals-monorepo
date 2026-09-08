import { describe, it, expect, vi, beforeEach } from "vitest";
import {
  render,
  screen,
  fireEvent,
  cleanup,
  act,
} from "@testing-library/react";
import { observable } from "mobx";
import { MemoryRouter, Routes, Route, useLocation } from "react-router";

// login.jsx calls Modal.setAppElement("#root") at import time.
vi.hoisted(() => {
  const root = document.createElement("div");
  root.id = "root";
  document.body.appendChild(root);
});

vi.mock("axios", () => import("../mocks/axios.js"));

// A mutable cookie jar: with no token the login form shows; with one
// the page redirects to the calendar.
vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));
import { cookies } from "../mocks/js_cookie.js";

// The login page renders only when there is no token cookie.
cookies.current = { timezone: "America/Los_Angeles" };

import axios from "axios";
import toastStore from "../../../app/frontend/src/stores/toast_store.js";
import { StoreContext } from "../../../app/frontend/src/helpers/store_context.jsx";
import { LOGIN_PATH } from "../../../app/frontend/src/routes.js";
import ResidentsLogin from "../../../app/frontend/src/components/residents/login.jsx";
import { fakeLocation } from "../helpers/fake_location.js";
import Cookie from "js-cookie";

function makeStore() {
  return observable({ isOnline: true });
}

function LocationEcho() {
  const location = useLocation();
  return <span data-testid="location">{location.pathname}</span>;
}

function renderLogin({ store = makeStore(), path = "/" } = {}) {
  render(
    <StoreContext.Provider value={store}>
      <MemoryRouter initialEntries={[path]}>
        <Routes>
          <Route path={LOGIN_PATH} element={<ResidentsLogin />} />
          <Route path="/calendar/*" element={null} />
        </Routes>
        <LocationEcho />
      </MemoryRouter>
    </StoreContext.Provider>,
  );
  return { store };
}

describe("ResidentsLogin", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    delete cookies.current.token;
    toastStore.clearAll();
  });

  it("shows the login form when signed out", () => {
    renderLogin();
    expect(screen.getByLabelText("email")).toBeInTheDocument();
    expect(screen.getByLabelText("password")).toBeInTheDocument();
    expect(screen.getByText("ONLINE")).toBeInTheDocument();
  });

  it("redirects to the calendar when a token cookie exists", () => {
    cookies.current.token = "token-abc";
    renderLogin();
    expect(screen.queryByLabelText("email")).not.toBeInTheDocument();
    expect(screen.getByTestId("location")).toHaveTextContent(/^\/calendar\//);
  });

  function typeCredentials() {
    fireEvent.change(screen.getByLabelText("email"), {
      target: { value: "jane@example.com" },
    });
    fireEvent.change(screen.getByLabelText("password"), {
      target: { value: "hunter2" },
    });
  }

  const SESSION = {
    token: "tok",
    community_id: 7,
    resident_id: 3,
    username: "Jane Smith",
    timezone: "America/Chicago",
  };

  it("submitting posts the credentials", () => {
    renderLogin();
    typeCredentials();
    fireEvent.click(screen.getByRole("button", { name: "Submit" }));

    expect(axios.post).toHaveBeenCalledWith("/api/v1/residents/token", {
      email: "jane@example.com",
      password: "hunter2",
    });
  });

  // A successful login stores the session in cookies and asks for a
  // full page load of the calendar, not a client-side route change
  // (#80).
  describe("a successful login", () => {
    it("writes the session cookies and reloads on today's calendar", async () => {
      axios.post.mockResolvedValue({ status: 200, data: SESSION });
      const { location, restore } = fakeLocation();
      try {
        renderLogin();
        typeCredentials();
        fireEvent.click(screen.getByRole("button", { name: "Submit" }));

        await vi.waitFor(() => {
          expect(location.href).toMatch(/^\/calendar\/all\/\d{4}-\d{2}-\d{2}$/);
        });
        const expires = { expires: 7300 };
        expect(Cookie.set).toHaveBeenCalledWith("token", "tok", expires);
        expect(Cookie.set).toHaveBeenCalledWith("community_id", 7, expires);
        expect(Cookie.set).toHaveBeenCalledWith("resident_id", 3, expires);
        expect(Cookie.set).toHaveBeenCalledWith(
          "username",
          "Jane Smith",
          expires,
        );
        expect(Cookie.set).toHaveBeenCalledWith(
          "timezone",
          "America/Chicago",
          expires,
        );
        // The loader stays up until the page is replaced.
        expect(screen.getByRole("button", { name: "Submit" })).toBeDisabled();
      } finally {
        restore();
      }
    });

    it("returns to the page the visitor was sent here from", async () => {
      axios.post.mockResolvedValue({
        status: 200,
        data: { ...SESSION, timezone: null },
      });
      const { location, restore } = fakeLocation();
      try {
        renderLogin({
          path: {
            pathname: "/",
            state: { from: { pathname: "/meals/42/edit" } },
          },
        });
        typeCredentials();
        fireEvent.click(screen.getByRole("button", { name: "Submit" }));

        await vi.waitFor(() => {
          expect(location.href).toBe("/meals/42/edit");
        });
        expect(Cookie.set).not.toHaveBeenCalledWith(
          "timezone",
          expect.anything(),
          expect.anything(),
        );
      } finally {
        restore();
      }
    });

    it("writes nothing when the answer lands after the page is gone", async () => {
      let deliver;
      axios.post.mockReturnValue(
        new Promise(function (resolve) {
          deliver = resolve;
        }),
      );
      renderLogin();
      typeCredentials();
      fireEvent.click(screen.getByRole("button", { name: "Submit" }));
      cleanup();

      await act(async () => deliver({ status: 200, data: SESSION }));
      expect(Cookie.set).not.toHaveBeenCalled();
    });
  });

  it("a refused login shows the reason and frees the form", async () => {
    axios.post.mockRejectedValue({
      response: { status: 400, data: { message: "Incorrect password" } },
    });
    renderLogin();
    typeCredentials();
    fireEvent.click(screen.getByRole("button", { name: "Submit" }));

    await vi.waitFor(() => {
      expect(toastStore.toasts.map((t) => t.message)).toEqual([
        "Incorrect password",
      ]);
    });
    expect(screen.getByRole("button", { name: "Submit" })).toBeEnabled();
  });

  it("a refusal that lands after the page is gone touches nothing", async () => {
    let fail;
    axios.post.mockReturnValue(
      new Promise(function (resolve, reject) {
        fail = reject;
      }),
    );
    renderLogin();
    typeCredentials();
    fireEvent.click(screen.getByRole("button", { name: "Submit" }));
    cleanup();

    await act(async () =>
      fail({ response: { status: 400, data: { message: "Incorrect" } } }),
    );
    expect(toastStore.toasts).toHaveLength(0);
  });

  it("password reset without an email shows an error and does not POST", () => {
    renderLogin();
    fireEvent.click(
      screen.getByRole("button", { name: "Reset your password" }),
    );

    expect(axios.post).not.toHaveBeenCalled();
    expect(toastStore.toasts[0].message).toBe("Email required.");
    expect(toastStore.toasts[0].type).toBe("error");
  });

  it("password reset posts the typed email", () => {
    axios.post.mockResolvedValue({
      status: 200,
      data: { message: "Password reset email sent." },
    });
    renderLogin();

    fireEvent.change(screen.getByLabelText("email"), {
      target: { value: "jane@example.com" },
    });
    fireEvent.click(
      screen.getByRole("button", { name: "Reset your password" }),
    );

    expect(axios.post).toHaveBeenCalledWith(
      "/api/v1/residents/password-reset",
      { email: "jane@example.com" },
    );
  });

  it("the reset-password path opens the new-password modal", async () => {
    axios.get.mockResolvedValue({ status: 200, data: { name: "Jane Smith" } });
    renderLogin({ path: "/reset-password/tok-1" });

    expect(
      await screen.findByText("Reset Password for Jane Smith"),
    ).toBeInTheDocument();
  });

  it("password reset shows the server's answer", async () => {
    axios.post.mockResolvedValue({
      status: 200,
      data: { message: "Check your email." },
    });
    renderLogin();
    fireEvent.change(screen.getByLabelText("email"), {
      target: { value: "jane@example.com" },
    });
    fireEvent.click(
      screen.getByRole("button", { name: "Reset your password" }),
    );

    await vi.waitFor(() => {
      expect(toastStore.toasts.map((t) => t.message)).toEqual([
        "Check your email.",
      ]);
    });
    expect(toastStore.toasts[0].type).toBe("success");
  });

  it("a refused password reset shows the reason", async () => {
    axios.post.mockRejectedValue({
      response: {
        status: 400,
        data: { message: "No resident with that email address." },
      },
    });
    renderLogin();
    fireEvent.change(screen.getByLabelText("email"), {
      target: { value: "jane@example.com" },
    });
    fireEvent.click(
      screen.getByRole("button", { name: "Reset your password" }),
    );

    await vi.waitFor(() => {
      expect(toastStore.toasts.map((t) => t.message)).toEqual([
        "No resident with that email address.",
      ]);
    });
    expect(
      screen.getByRole("button", { name: "Reset your password" }),
    ).toBeEnabled();
  });

  it("a password reset answer after the page is gone touches nothing", async () => {
    let deliver;
    let fail;
    axios.post
      .mockReturnValueOnce(
        new Promise(function (resolve) {
          deliver = resolve;
        }),
      )
      .mockReturnValueOnce(
        new Promise(function (resolve, reject) {
          fail = reject;
        }),
      );
    renderLogin();
    fireEvent.change(screen.getByLabelText("email"), {
      target: { value: "jane@example.com" },
    });
    const reset = screen.getByRole("button", { name: "Reset your password" });
    fireEvent.click(reset);
    cleanup();
    await act(async () => deliver({ status: 200, data: { message: "Ok." } }));

    renderLogin();
    fireEvent.change(screen.getByLabelText("email"), {
      target: { value: "jane@example.com" },
    });
    fireEvent.click(
      screen.getByRole("button", { name: "Reset your password" }),
    );
    cleanup();
    await act(async () =>
      fail({ response: { status: 400, data: { message: "No." } } }),
    );

    expect(toastStore.toasts).toHaveLength(0);
  });

  it("Escape closes the new-password modal back to the login page", async () => {
    axios.get.mockResolvedValue({ status: 200, data: { name: "Jane Smith" } });
    renderLogin({ path: "/reset-password/tok-1" });
    await screen.findByText("Reset Password for Jane Smith");

    fireEvent.keyDown(screen.getByRole("dialog"), {
      key: "Escape",
      keyCode: 27,
    });
    expect(screen.getByTestId("location")).toHaveTextContent(/^\/$/);
  });

  it("shows OFFLINE when the connection drops", () => {
    renderLogin({ store: observable({ isOnline: false }) });
    expect(screen.getByText("OFFLINE")).toBeInTheDocument();
  });
});
