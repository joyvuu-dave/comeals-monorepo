// Asks React Router itself which paths are pages of the app, for
// spec/lib/app_pages_contract_spec.rb. Reads a JSON array of paths on
// stdin and writes a JSON array of true or false, one for each: true when
// the routes AppRoutes draws (components/app/app_routes.jsx) send that
// path to a page of routes.json, false when they send it to Page not
// found. The server's copy of the rules (lib/app_pages.rb) must give the
// same answer for every path.
import { readFileSync } from "node:fs";
import { matchRoutes } from "react-router";

const routesFile = new URL(
  "../../app/frontend/src/routes.json",
  import.meta.url,
);
const { pages } = JSON.parse(readFileSync(routesFile, "utf8"));
const routes = [
  ...Object.values(pages).map((page) => ({ path: page.path })),
  { path: "*" },
];

// React Router warns on a path it cannot decode, and then matches it as
// it was sent. The warning is expected here, so it is not printed.
console.warn = () => {};

const paths = JSON.parse(readFileSync(0, "utf8"));
const answers = paths.map((path) => {
  const matches = matchRoutes(routes, path);
  return matches !== null && matches[0].route.path !== "*";
});
process.stdout.write(JSON.stringify(answers));
