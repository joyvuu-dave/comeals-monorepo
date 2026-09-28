import { describe, it, expect } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { MemoryRouter, Routes, Route, useLocation } from "react-router";
import ButtonBar from "../../../app/frontend/src/components/meal/button_bar.jsx";

function LocationEcho() {
  const location = useLocation();
  return <span data-testid="location">{location.pathname}</span>;
}

// ButtonBar takes no props and reads no store: it reads the path from
// the router. Header renders it the same way, as a bare <ButtonBar />.
function renderBar(path) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route path="*" element={<ButtonBar />} />
      </Routes>
      <LocationEcho />
    </MemoryRouter>,
  );
}

describe("ButtonBar", () => {
  it("opens the history modal path from the meal page", () => {
    renderBar("/meals/42/edit/");
    fireEvent.click(screen.getByRole("button", { name: "history" }));
    expect(screen.getByTestId("location")).toHaveTextContent(
      "/meals/42/edit/history/",
    );
  });

  it("leaves the history path when already on it", () => {
    renderBar("/meals/42/edit/history/");
    fireEvent.click(screen.getByRole("button", { name: "history" }));
    // split("/history")[0] drops the trailing slash too — pinned as-is.
    expect(screen.getByTestId("location")).toHaveTextContent(
      /^\/meals\/42\/edit$/,
    );
  });
});
