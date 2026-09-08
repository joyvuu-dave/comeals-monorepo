import { describe, it, expect } from "vitest";
import { render } from "@testing-library/react";
import Icon from "../../../app/frontend/src/components/icon.jsx";

describe("Icon", () => {
  it("draws the named icon, hidden from screen readers", () => {
    const { container } = render(<Icon name="xmark" />);
    const svg = container.querySelector("svg");
    expect(svg).toHaveClass("icon-xmark");
    expect(svg).toHaveAttribute("aria-hidden", "true");
    expect(svg.querySelector("path")).toHaveAttribute("d");
  });

  it("scales with the size it is given", () => {
    const { container } = render(<Icon name="chevron-left" size="2x" />);
    expect(container.querySelector("svg").style.fontSize).toBe("2em");
  });
});
