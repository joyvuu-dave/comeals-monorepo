import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { MemoryRouter, Routes, Route } from "react-router";

vi.mock("axios", () => ({
  default: {
    get: vi.fn(),
    post: vi.fn(),
  },
}));

import axios from "axios";
import ResidentsPasswordNew from "../../../app/frontend/src/components/residents/password_new.jsx";

// The component gets the token from the route. The class version reads
// it from match/history props (passed by login.jsx); the hooks version
// reads the router directly. The test provides both, so it pins
// behavior across the conversion.
function renderForm() {
  const match = { params: { modal: "reset-password", token: "tok-1" } };
  const history = { push: vi.fn() };
  render(
    <MemoryRouter initialEntries={["/reset-password/tok-1/"]}>
      <Routes>
        <Route
          path="/:modal/:token/*"
          element={<ResidentsPasswordNew match={match} history={history} />}
        />
      </Routes>
    </MemoryRouter>,
  );
  return { history };
}

describe("ResidentsPasswordNew", () => {
  beforeEach(() => {
    vi.clearAllMocks();
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
});
