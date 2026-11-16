import type { ReactNode } from "react";
import { Routes, Route } from "react-router";
import { PAGES, NOT_FOUND_PATH } from "../../routes";
import NotFound from "./not_found";

// The app's routes: one <Route> for each page in routes.json, the list
// the server reads too, and "Page not found" for every other address.
// This is the only file that may draw a <Route> (the ESLint rule in
// eslint.config.js), so a page cannot exist here without being in that
// list, and so be refused by the server (ADR 0016).
//
// `elements` maps each page's name in routes.json to what it shows. A
// page with no element, or an element with no page, throws: every test
// that draws the app then fails, with the name in the message.
type PageName = keyof typeof PAGES;

export default function AppRoutes({
  elements,
}: {
  elements: Record<string, ReactNode>;
}) {
  const pages = Object.keys(PAGES) as PageName[];
  const missing = pages.filter((name) => !(name in elements));
  const extra = Object.keys(elements).filter((name) => !(name in PAGES));
  if (missing.length > 0 || extra.length > 0) {
    throw new Error(
      `The pages in routes.json and the elements given to AppRoutes differ. ` +
        `In routes.json with no element: ${missing.join(", ") || "none"}. ` +
        `With an element but not in routes.json: ${extra.join(", ") || "none"}.`,
    );
  }

  return (
    <Routes>
      {pages.map((name) => (
        <Route key={name} path={PAGES[name].path} element={elements[name]} />
      ))}
      <Route path={NOT_FOUND_PATH} element={<NotFound />} />
    </Routes>
  );
}
