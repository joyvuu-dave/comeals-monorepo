import { describe, it, expect, beforeEach, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import { MemoryRouter, Routes, Route, useLocation } from "react-router";

vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));
import { cookies } from "../mocks/js_cookie.js";

import PrivateRoute from "../../../app/frontend/src/components/app/private_route.jsx";

function LoginEcho() {
  const location = useLocation();
  return (
    <span data-testid="login">
      login, from {location.state ? location.state.from.pathname : "nowhere"}
    </span>
  );
}

function renderAt(path) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route path="/" element={<LoginEcho />} />
        <Route
          path="/meals/:id/edit"
          element={
            <PrivateRoute>
              <span>the meal</span>
            </PrivateRoute>
          }
        />
      </Routes>
    </MemoryRouter>,
  );
}

describe("PrivateRoute", () => {
  beforeEach(() => {
    cookies.current = { token: "test-token" };
  });

  it("shows the page when a token cookie exists", () => {
    renderAt("/meals/42/edit");
    expect(screen.getByText("the meal")).toBeInTheDocument();
  });

  it("sends a signed-out visitor to login, remembering where they were", () => {
    delete cookies.current.token;
    renderAt("/meals/42/edit");
    expect(screen.getByTestId("login")).toHaveTextContent(
      "login, from /meals/42/edit",
    );
  });

  // The token cookie lives for twenty years, so a cookie written as the
  // string "undefined" by an old build is still out there.
  it("treats a cookie holding the word undefined as signed out", () => {
    cookies.current.token = "undefined";
    renderAt("/meals/42/edit");
    expect(screen.getByTestId("login")).toBeInTheDocument();
  });
});
