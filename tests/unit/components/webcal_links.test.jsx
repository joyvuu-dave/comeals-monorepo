import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, act } from "@testing-library/react";

// A mutable cookie jar so each test controls whether resident_id is
// already known.
vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));
import { cookies } from "../mocks/js_cookie.js";

cookies.current = { community_id: "7" };

vi.mock("axios", () => import("../mocks/axios.js"));

import Cookie from "js-cookie";
import axios from "axios";
import WebcalLinks from "../../../app/frontend/src/components/calendar/webcal_links.jsx";

describe("WebcalLinks", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    delete cookies.current.resident_id;
    delete cookies.current.token;
  });

  // Logout removes every session cookie just before the page reloads,
  // and a calendar that mounts in between drew these links. With no
  // token, the server can only answer 401, so nothing is asked (#153).
  it("asks for no resident id after the session ended", async () => {
    render(<WebcalLinks />);
    await act(async () => {});

    expect(axios.get).not.toHaveBeenCalled();
    expect(
      screen.queryByRole("link", { name: "Subscribe to My Meals" }),
    ).not.toBeInTheDocument();
  });

  // The same moment, with the community id gone too. The link to the
  // community's feed was drawn as /communities/undefined/ical.ics (#153).
  it("draws no link after the community id is gone", async () => {
    delete cookies.current.community_id;
    cookies.current.resident_id = "3";
    const { container } = render(<WebcalLinks />);
    await act(async () => {});

    expect(container.querySelectorAll("a")).toHaveLength(0);
    expect(axios.get).not.toHaveBeenCalled();
  });

  it("links both calendars when the resident is already known", () => {
    cookies.current.resident_id = "3";
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
    cookies.current.token = "test-token";
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

  // The calendar can go away (a meal opened, the idle timer) before the
  // id arrives. The answer is then dropped: nothing is drawn, and the
  // cookie is not written from a component that is gone.
  it("drops the id that arrives after the links went away", async () => {
    cookies.current.token = "test-token";
    let answer;
    axios.get.mockReturnValue(
      new Promise((resolve) => {
        answer = resolve;
      }),
    );
    const { unmount } = render(<WebcalLinks />);

    unmount();
    await act(async () => {
      answer({ status: 200, data: 9 });
    });

    expect(axios.get).toHaveBeenCalledWith("/api/v1/residents/id");
    expect(Cookie.set).not.toHaveBeenCalled();
  });

  it("shows only the community link when the id fetch fails", async () => {
    cookies.current.token = "test-token";
    axios.get.mockRejectedValue({ response: { status: 500, data: {} } });
    render(<WebcalLinks />);

    await act(async () => {});
    expect(
      screen.getByRole("link", { name: "Subscribe to All Meals" }),
    ).toBeInTheDocument();
    expect(
      screen.queryByRole("link", { name: "Subscribe to My Meals" }),
    ).not.toBeInTheDocument();
    expect(Cookie.set).not.toHaveBeenCalled();
  });
});
