import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { observable } from "mobx";
import { Provider } from "mobx-react";
import { MemoryRouter, Routes, Route, useLocation } from "react-router";

// login.jsx calls Modal.setAppElement("#root") at import time.
vi.hoisted(() => {
  const root = document.createElement("div");
  root.id = "root";
  document.body.appendChild(root);
});

vi.mock("axios", () => ({
  default: {
    get: vi.fn(),
    post: vi.fn(),
  },
}));

// A mutable cookie jar: with no token the login form shows; with one
// the page redirects to the calendar.
const cookies = { timezone: "America/Los_Angeles" };
vi.mock("js-cookie", () => ({
  default: {
    get: vi.fn((name) => cookies[name]),
    set: vi.fn(),
    remove: vi.fn(),
  },
}));

import axios from "axios";
import toastStore from "../../../app/frontend/src/stores/toast_store.js";
import { StoreContext } from "../../../app/frontend/src/helpers/store_context.jsx";
import { LOGIN_PATH } from "../../../app/frontend/src/routes.js";
import ResidentsLogin from "../../../app/frontend/src/components/residents/login.jsx";

function makeStore() {
  return observable({ isOnline: true });
}

function LocationEcho() {
  const location = useLocation();
  return <span data-testid="location">{location.pathname}</span>;
}

// Both providers so the test holds across the inject() → useStore()
// conversion; the real router replaces the withRouter props.
function renderLogin({ store = makeStore(), path = "/" } = {}) {
  render(
    <Provider store={store}>
      <StoreContext.Provider value={store}>
        <MemoryRouter initialEntries={[path]}>
          <Routes>
            <Route path={LOGIN_PATH} element={<ResidentsLogin />} />
            <Route path="/calendar/*" element={null} />
          </Routes>
          <LocationEcho />
        </MemoryRouter>
      </StoreContext.Provider>
    </Provider>,
  );
  return { store };
}

describe("ResidentsLogin", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    delete cookies.token;
    toastStore.clearAll();
  });

  it("shows the login form when signed out", () => {
    renderLogin();
    expect(screen.getByLabelText("email")).toBeInTheDocument();
    expect(screen.getByLabelText("password")).toBeInTheDocument();
    expect(screen.getByText("ONLINE")).toBeInTheDocument();
  });

  it("redirects to the calendar when a token cookie exists", () => {
    cookies.token = "token-abc";
    renderLogin();
    expect(screen.queryByLabelText("email")).not.toBeInTheDocument();
    expect(screen.getByTestId("location")).toHaveTextContent(/^\/calendar\//);
  });

  it("submitting posts the credentials", () => {
    // A non-200 response: the success path assigns window.location,
    // which jsdom cannot do.
    axios.post.mockResolvedValue({ status: 204, data: {} });
    renderLogin();

    fireEvent.change(screen.getByLabelText("email"), {
      target: { value: "jane@example.com" },
    });
    fireEvent.change(screen.getByLabelText("password"), {
      target: { value: "hunter2" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Submit" }));

    expect(axios.post).toHaveBeenCalledWith("/api/v1/residents/token", {
      email: "jane@example.com",
      password: "hunter2",
    });
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
});
