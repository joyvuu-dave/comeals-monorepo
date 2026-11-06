import { describe, it, expect, vi, beforeEach } from "vitest";
import { vitestWaitFor } from "../helpers/wait_for.js";
import { render, screen } from "@testing-library/react";
import { MemoryRouter, Routes, Route, useLocation } from "react-router";

vi.mock("axios", () => import("../mocks/axios.js"));

import axios from "axios";
import toastStore from "../../../app/frontend/src/stores/toast_store.js";
import { messagesShown } from "../helpers/form_messages.js";
import ResidentsEmailConfirm, {
  NO_TOKEN,
} from "../../../app/frontend/src/components/residents/email_confirm.tsx";

function LocationEcho() {
  const location = useLocation();
  return (
    <span data-testid="location">{location.pathname + location.hash}</span>
  );
}

function renderPage(address) {
  render(
    <MemoryRouter initialEntries={[address]}>
      <Routes>
        <Route path="/confirm-email" element={<ResidentsEmailConfirm />} />
        <Route path="/" element={<span>home</span>} />
      </Routes>
      <LocationEcho />
    </MemoryRouter>,
  );
}

describe("ResidentsEmailConfirm", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    toastStore.clearAll();
  });

  it("opens the link, says what changed, and goes on to the home page", async () => {
    axios.post.mockResolvedValue({
      status: 200,
      data: { message: "Your email is now new@example.com." },
    });
    renderPage("/confirm-email#token=tok-1");

    expect(
      screen.getByRole("heading", { name: "Changing your email..." }),
    ).toBeVisible();
    await screen.findByText("home");
    expect(axios.post).toHaveBeenCalledWith("/api/v1/profile/email-confirm", {
      email_token: "tok-1",
    });
    expect(messagesShown().stack).toEqual([
      "Your email is now new@example.com.",
    ]);
    // The token does not stay in the address.
    expect(screen.getByTestId("location")).toHaveTextContent(/^\/$/);
  });

  it("shows the server's reason when the link does not work", async () => {
    axios.post.mockRejectedValue({
      response: { status: 400, data: { message: "This link has expired." } },
    });
    renderPage("/confirm-email#token=tok-1");

    await screen.findByText("home");
    await vitestWaitFor(() =>
      expect(messagesShown().stack).toEqual(["This link has expired."]),
    );
  });

  it("asks nothing of the server when the link has no token", async () => {
    renderPage("/confirm-email");

    await screen.findByText("home");
    expect(axios.post).not.toHaveBeenCalled();
    expect(messagesShown().stack).toEqual([NO_TOKEN]);
  });
});
