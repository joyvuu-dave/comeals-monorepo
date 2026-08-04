import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen } from "@testing-library/react";

// A mutable cookie jar so each test controls whether resident_id is
// already known.
const cookies = { community_id: "7" };
vi.mock("js-cookie", () => ({
  default: {
    get: vi.fn((name) => cookies[name]),
    set: vi.fn(),
  },
}));

vi.mock("axios", () => ({
  default: {
    get: vi.fn(),
  },
}));

import Cookie from "js-cookie";
import axios from "axios";
import WebcalLinks from "../../../app/frontend/src/components/calendar/webcal_links.jsx";

describe("WebcalLinks", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    delete cookies.resident_id;
  });

  it("links both calendars when the resident is already known", () => {
    cookies.resident_id = "3";
    render(<WebcalLinks />);

    const all = screen.getByRole("link", { name: "Subscribe to All Meals" });
    expect(all).toHaveAttribute(
      "href",
      expect.stringContaining("/api/v1/communities/7/ical.ics"),
    );
    const mine = screen.getByRole("link", { name: "Subscribe to My Meals" });
    expect(mine).toHaveAttribute(
      "href",
      expect.stringContaining("/api/v1/residents/3/ical.ics"),
    );
    expect(axios.get).not.toHaveBeenCalled();
  });

  it("fetches the resident id when the cookie is missing", async () => {
    axios.get.mockResolvedValue({ status: 200, data: 9 });
    render(<WebcalLinks />);

    // The personal link waits for the id; the community link does not.
    expect(
      screen.getByRole("link", { name: "Subscribe to All Meals" }),
    ).toBeInTheDocument();
    expect(
      screen.queryByRole("link", { name: "Subscribe to My Meals" }),
    ).not.toBeInTheDocument();

    const mine = await screen.findByRole("link", {
      name: "Subscribe to My Meals",
    });
    expect(mine).toHaveAttribute(
      "href",
      expect.stringContaining("/api/v1/residents/9/ical.ics"),
    );
    expect(axios.get).toHaveBeenCalledWith("/api/v1/residents/id");
    expect(Cookie.set).toHaveBeenCalledWith("resident_id", 9, {
      expires: 7300,
    });
  });
});
