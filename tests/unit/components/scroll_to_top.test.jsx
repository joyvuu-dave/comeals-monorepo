import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { MemoryRouter, useNavigate } from "react-router";
import ScrollToTop from "../../../app/frontend/src/components/app/scroll_to_top.jsx";

function NavButtons() {
  const navigate = useNavigate();
  return (
    <>
      <button onClick={() => navigate("/meals/42/edit/")}>to meal</button>
      <button onClick={() => navigate("/calendar/all/2026-02-15/")}>
        to next month
      </button>
    </>
  );
}

function renderAt(path) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <ScrollToTop>
        <NavButtons />
      </ScrollToTop>
    </MemoryRouter>,
  );
}

describe("ScrollToTop", () => {
  beforeEach(() => {
    window.scrollTo = vi.fn();
    // jsdom's default innerWidth is 1024 — the desktop branch.
  });

  it("renders its children", () => {
    renderAt("/calendar/all/2026-01-15/");
    expect(screen.getByRole("button", { name: "to meal" })).toBeInTheDocument();
  });

  it("scrolls to the top when moving from calendar to a meal", () => {
    renderAt("/calendar/all/2026-01-15/");
    fireEvent.click(screen.getByRole("button", { name: "to meal" }));
    expect(window.scrollTo).toHaveBeenCalledWith(0, 0);
  });

  it("does not scroll when switching months on the calendar", () => {
    renderAt("/calendar/all/2026-01-15/");
    fireEvent.click(screen.getByRole("button", { name: "to next month" }));
    expect(window.scrollTo).not.toHaveBeenCalled();
  });
});
