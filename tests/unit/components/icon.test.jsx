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

  it("keeps a class name and a size it is given", () => {
    const { container } = render(
      <Icon name="chevron-left" className="mar-sm" size="2x" />,
    );
    const svg = container.querySelector("svg");
    expect(svg).toHaveClass("icon-chevron-left");
    expect(svg).toHaveClass("mar-sm");
    expect(svg.style.fontSize).toBe("2em");
  });

  it("is exposed to screen readers when it carries a label", () => {
    const { container } = render(<Icon name="arrow-left" aria-label="Back" />);
    const svg = container.querySelector("svg");
    expect(svg).not.toHaveAttribute("aria-hidden");
    expect(svg).toHaveAttribute("aria-label", "Back");
  });
});
