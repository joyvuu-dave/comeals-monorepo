import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, act } from "@testing-library/react";

vi.mock("axios", () => import("../mocks/axios.js"));

import axios from "axios";
import RotationsShow from "../../../app/frontend/src/components/rotations/show.jsx";

describe("RotationsShow", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("renders a loading skeleton first, then the title with the place value", async () => {
    axios.get.mockResolvedValue({
      status: 200,
      data: {
        id: 10,
        place_value: 3,
        description: "Kitchen cleaning",
        residents: [],
      },
    });
    render(<RotationsShow id="10" />);

    expect(screen.getByText("Rotation")).toBeInTheDocument();
    expect(screen.getByText("Loading...")).toBeInTheDocument();

    expect(await screen.findByText("Kitchen cleaning")).toBeInTheDocument();
    // The number is the place value from the response, never the
    // database id from the URL.
    expect(screen.getByText("Rotation 3")).toBeInTheDocument();
    expect(screen.queryByText("Rotation 10")).not.toBeInTheDocument();
    expect(screen.queryByText("Loading...")).not.toBeInTheDocument();
    expect(axios.get).toHaveBeenCalledWith("/api/v1/rotations/10");
  });

  // The server sends display_name as "unit - name"
  // (RotationLogSerializer), and the list sorts by that whole string: by
  // unit first, then by name within a unit.
  it("sorts residents by unit, then name, and strikes through the ones signed up", async () => {
    axios.get.mockResolvedValue({
      status: 200,
      data: {
        id: 10,
        place_value: 3,
        description: "Kitchen cleaning",
        residents: [
          { id: 1, display_name: "B - Alice Jones", signed_up: false },
          { id: 2, display_name: "A - Zed Park", signed_up: true },
          { id: 3, display_name: "C - Bob Lee", signed_up: false },
          { id: 4, display_name: "A - Amy Chu", signed_up: false },
        ],
      },
    });
    const { container } = render(<RotationsShow id="10" />);

    await screen.findByText("Kitchen cleaning");
    const items = [...container.querySelectorAll("li")].map(
      (li) => li.textContent,
    );
    expect(items).toEqual([
      "A - Amy Chu",
      "A - Zed Park",
      "B - Alice Jones",
      "C - Bob Lee",
    ]);

    // Zed signed up: struck through and muted, not bold. The s element
    // sits inside the li — a ul may only directly contain li elements.
    expect(container.querySelectorAll("li.text-muted s")).toHaveLength(1);
    expect(container.querySelector("li.text-muted s")).toHaveTextContent(
      "A - Zed Park",
    );
    expect(screen.getByText("B - Alice Jones")).toHaveClass("text-bold");
  });

  it("says so when the rotation fails to load", async () => {
    axios.get.mockRejectedValue({ message: "boom" });
    render(<RotationsShow id="10" />);

    expect(
      await screen.findByText("Failed to load rotation."),
    ).toBeInTheDocument();
  });

  // The calendar renders this modal without a key, so a new id in the
  // URL gives the same component a new id. The request for the old id
  // may still be open, and its answer must not replace the new one.
  describe("when the id changes while a request is open", () => {
    function deferredGets() {
      const pending = {};
      axios.get.mockImplementation(
        (url) =>
          new Promise((resolve, reject) => {
            pending[url] = { resolve, reject };
          }),
      );
      return pending;
    }

    const ROTATION_11 = {
      status: 200,
      data: {
        id: 11,
        place_value: 4,
        description: "Window cleaning",
        residents: [],
      },
    };

    it("drops the old id's answer when it arrives last", async () => {
      const pending = deferredGets();
      const { rerender } = render(<RotationsShow id="10" />);
      rerender(<RotationsShow id="11" />);

      await act(async () => {
        pending["/api/v1/rotations/11"].resolve(ROTATION_11);
      });
      await act(async () => {
        pending["/api/v1/rotations/10"].resolve({
          status: 200,
          data: {
            id: 10,
            place_value: 3,
            description: "Kitchen cleaning",
            residents: [],
          },
        });
      });

      expect(screen.getByText("Rotation 4")).toBeInTheDocument();
      expect(screen.getByText("Window cleaning")).toBeInTheDocument();
      expect(screen.queryByText("Kitchen cleaning")).not.toBeInTheDocument();
    });

    it("drops the old id's failure when it arrives last", async () => {
      const pending = deferredGets();
      const { rerender } = render(<RotationsShow id="10" />);
      rerender(<RotationsShow id="11" />);

      await act(async () => {
        pending["/api/v1/rotations/11"].resolve(ROTATION_11);
      });
      await act(async () => {
        pending["/api/v1/rotations/10"].reject({ message: "boom" });
      });

      expect(screen.getByText("Window cleaning")).toBeInTheDocument();
      expect(
        screen.queryByText("Failed to load rotation."),
      ).not.toBeInTheDocument();
    });
  });
});
