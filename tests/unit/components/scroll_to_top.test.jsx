import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, act } from "@testing-library/react";
import { MemoryRouter, useNavigate } from "react-router";
import ScrollToTop from "../../../app/frontend/src/components/app/scroll_to_top.jsx";

let navigate;
function CaptureNavigate() {
  navigate = useNavigate();
  return <p>child page</p>;
}

function renderAt(path) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <ScrollToTop>
        <CaptureNavigate />
      </ScrollToTop>
    </MemoryRouter>,
  );
}

const CALENDAR = "/calendar/all/2026-01-15/";
const NEXT_MONTH = "/calendar/all/2026-02-15/";
const OTHER_TYPE = "/calendar/meals/2026-01-15/";
const MEAL = "/meals/42/edit/";
const OTHER_MEAL = "/meals/43/edit/";

describe("ScrollToTop", () => {
  const jsdomWidth = window.innerWidth;
  const jsdomScrollTo = window.scrollTo;

  beforeEach(() => {
    window.scrollTo = vi.fn();
  });

  afterEach(() => {
    window.innerWidth = jsdomWidth;
    window.scrollTo = jsdomScrollTo;
  });

  // A meal page on a wide screen: any move there would scroll, so this
  // shows the first render is not counted as a move.
  it("renders its children and does not scroll on the first page", () => {
    window.innerWidth = 1024;
    renderAt(MEAL);
    expect(screen.getByText("child page")).toBeInTheDocument();
    expect(window.scrollTo).not.toHaveBeenCalled();
  });

  // Moving between the calendar and a meal scrolls on any screen. On a
  // screen 825 pixels wide or more, any other move scrolls too, except
  // a month change in the same calendar type. On a narrower screen,
  // nothing else scrolls: the reader keeps their place.
  it.each([
    { width: 400, from: CALENDAR, to: MEAL, scrolls: true },
    { width: 400, from: MEAL, to: CALENDAR, scrolls: true },
    { width: 400, from: MEAL, to: OTHER_MEAL, scrolls: false },
    { width: 400, from: CALENDAR, to: OTHER_TYPE, scrolls: false },
    { width: 400, from: CALENDAR, to: NEXT_MONTH, scrolls: false },
    { width: 824, from: MEAL, to: OTHER_MEAL, scrolls: false },
    { width: 825, from: MEAL, to: OTHER_MEAL, scrolls: true },
    { width: 1024, from: CALENDAR, to: MEAL, scrolls: true },
    { width: 1024, from: MEAL, to: CALENDAR, scrolls: true },
    { width: 1024, from: MEAL, to: OTHER_MEAL, scrolls: true },
    { width: 1024, from: CALENDAR, to: OTHER_TYPE, scrolls: true },
    { width: 1024, from: CALENDAR, to: NEXT_MONTH, scrolls: false },
  ])(
    "at $width pixels wide, $from to $to scrolls: $scrolls",
    ({ width, from, to, scrolls }) => {
      window.innerWidth = width;
      renderAt(from);

      act(() => {
        navigate(to);
      });

      if (scrolls) {
        expect(window.scrollTo).toHaveBeenCalledTimes(1);
        expect(window.scrollTo).toHaveBeenCalledWith(0, 0);
      } else {
        expect(window.scrollTo).not.toHaveBeenCalled();
      }
    },
  );
});
