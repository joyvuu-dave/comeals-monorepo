import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen } from "@testing-library/react";

vi.mock("axios", () => import("../mocks/axios.js"));

// toCommunityDayjs reads the community timezone from a cookie.
vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));
import { cookies } from "../mocks/js_cookie.js";
cookies.current = { timezone: "America/Los_Angeles" };

import axios from "axios";
import dayjs from "dayjs";
import advancedFormat from "dayjs/plugin/advancedFormat";
import MealHistoryShow from "../../../app/frontend/src/components/history/show.jsx";

// index.jsx registers this plugin at app startup; the "Do" ordinal in
// the date header needs it.
dayjs.extend(advancedFormat);

describe("MealHistoryShow", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("shows Loading, then the audit table", async () => {
    axios.get.mockResolvedValue({
      status: 200,
      data: {
        date: "2026-01-15",
        items: [
          {
            id: 1,
            user_name: "Jane Smith",
            description: "signed up",
            display_time: "2026-01-14T18:30:00Z",
          },
          {
            id: 2,
            user_name: "Bob Johnson",
            description: "added a guest",
            display_time: "2026-01-14T19:00:00Z",
          },
        ],
      },
    });
    render(<MealHistoryShow id="42" />);

    expect(screen.getByText("Loading...")).toBeInTheDocument();

    expect(await screen.findByText("Thu, Jan 15th")).toBeInTheDocument();
    expect(axios.get).toHaveBeenCalledWith("/api/v1/meals/42/history");

    expect(
      screen.getByRole("columnheader", { name: "User" }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("cell", { name: "Jane Smith" }),
    ).toBeInTheDocument();
    expect(screen.getByRole("cell", { name: "signed up" })).toBeInTheDocument();
    expect(
      screen.getByRole("cell", { name: "added a guest" }),
    ).toBeInTheDocument();
  });
});
