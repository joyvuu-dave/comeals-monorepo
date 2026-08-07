import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen } from "@testing-library/react";

vi.mock("axios", () => import("../mocks/axios.js"));

import axios from "axios";
import RotationsShow from "../../../app/frontend/src/components/rotations/show.jsx";

describe("RotationsShow", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("renders the title from props and a loading skeleton first", async () => {
    axios.get.mockResolvedValue({
      status: 200,
      data: { description: "Kitchen cleaning", residents: [] },
    });
    render(<RotationsShow id="10" />);

    expect(screen.getByText("Rotation 10")).toBeInTheDocument();
    expect(screen.getByText("Loading...")).toBeInTheDocument();

    expect(await screen.findByText("Kitchen cleaning")).toBeInTheDocument();
    expect(screen.queryByText("Loading...")).not.toBeInTheDocument();
    expect(axios.get).toHaveBeenCalledWith("/api/v1/rotations/10");
  });

  it("sorts residents by name and strikes through the signed up", async () => {
    axios.get.mockResolvedValue({
      status: 200,
      data: {
        description: "Kitchen cleaning",
        residents: [
          { id: 1, display_name: "Jane", signed_up: true },
          { id: 3, display_name: "Alice", signed_up: false },
          { id: 2, display_name: "Bob", signed_up: false },
        ],
      },
    });
    const { container } = render(<RotationsShow id="10" />);

    await screen.findByText("Kitchen cleaning");
    const items = [...container.querySelectorAll("li")].map(
      (li) => li.textContent,
    );
    expect(items).toEqual(["Alice", "Bob", "Jane"]);

    // Jane signed up: struck through and muted, not bold. The s element
    // sits inside the li — a ul may only directly contain li elements.
    expect(container.querySelector("li.text-muted s")).toHaveTextContent(
      "Jane",
    );
    expect(screen.getByText("Alice")).toHaveClass("text-bold");
  });

  it("says so when the rotation fails to load", async () => {
    axios.get.mockRejectedValue({ message: "boom" });
    render(<RotationsShow id="10" />);

    expect(
      await screen.findByText("Failed to load rotation."),
    ).toBeInTheDocument();
  });
});
