import { describe, it, expect, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import AppRoutes from "../../../app/frontend/src/components/app/app_routes";
import { PAGES } from "../../../app/frontend/src/routes.js";

// AppRoutes draws one route for each page of routes.json, the list the
// server reads too (ADR 0016), and Page not found for every other
// address.

function elementsNamed() {
  return Object.fromEntries(
    Object.keys(PAGES).map((name) => [name, <p>page {name}</p>]),
  );
}

function renderAt(address, elements = elementsNamed()) {
  render(
    <MemoryRouter initialEntries={[address]}>
      <AppRoutes elements={elements} />
    </MemoryRouter>,
  );
}

describe("AppRoutes", () => {
  it.each(
    Object.entries(PAGES).flatMap(([name, page]) =>
      page.examples.map((example) => [example, name]),
    ),
  )("shows %s as the %s page", (example, name) => {
    renderAt(example);

    expect(screen.getByText(`page ${name}`)).toBeInTheDocument();
  });

  it.each(["/foo", "/calendar", "/meals/1/edit/x", "/reset-password/tok"])(
    "shows Page not found at %s, with a way back",
    (address) => {
      renderAt(address);

      expect(
        screen.getByRole("heading", { name: "Page not found" }),
      ).toBeInTheDocument();
      expect(
        screen.getByRole("link", { name: "Go to Comeals" }),
      ).toHaveAttribute("href", "/");
    },
  );

  // A page added to routes.json with nothing to show, or something to
  // show for a page the list does not have, fails every test that draws
  // the app, with the names.
  it("throws when a page of routes.json has no element", () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const elements = elementsNamed();
    delete elements.calendar;

    expect(() => renderAt("/", elements)).toThrow(
      "In routes.json with no element: calendar. With an element but not in routes.json: none.",
    );
    vi.restoreAllMocks();
  });

  it("throws when an element has no page in routes.json", () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const elements = { ...elementsNamed(), profile: <p>profile</p> };

    expect(() => renderAt("/", elements)).toThrow(
      "In routes.json with no element: none. With an element but not in routes.json: profile.",
    );
    vi.restoreAllMocks();
  });
});
