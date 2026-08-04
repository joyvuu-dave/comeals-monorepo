import { describe, it, expect } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { observable } from "mobx";
import {
  MemoryRouter,
  Routes,
  Route,
  useLocation,
  useNavigate,
} from "react-router";
import { StoreContext } from "../../../app/frontend/src/helpers/store_context.jsx";
import ButtonBar from "../../../app/frontend/src/components/meal/button_bar.jsx";

function LocationEcho() {
  const location = useLocation();
  return <span data-testid="location">{location.pathname}</span>;
}

// The class version reads history/location props (passed by Header);
// the hooks version reads the router directly. The bridge hands the
// class real router-backed props, so the same assertions hold for
// both.
function Bridge({ store }) {
  const navigate = useNavigate();
  const location = useLocation();
  return (
    <StoreContext.Provider value={store}>
      <ButtonBar history={{ push: navigate }} location={location} />
    </StoreContext.Provider>
  );
}

function renderBar(path) {
  const store = observable({});
  return render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route path="*" element={<Bridge store={store} />} />
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
