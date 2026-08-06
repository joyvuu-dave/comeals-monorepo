import { useEffect, useRef } from "react";
import { useLocation } from "react-router";

function ScrollToTop({ children }) {
  const location = useLocation();
  const prevPathnameRef = useRef(location.pathname);

  useEffect(
    function () {
      const prevPathname = prevPathnameRef.current;
      prevPathnameRef.current = location.pathname;
      if (prevPathname === location.pathname) {
        return;
      }

      // Path shape: /calendar/:type/:date or /meals/:id/edit, so
      // parts[1] is the page and parts[2] the calendar type.
      const current = location.pathname.split("/");
      const prev = prevPathname.split("/");

      const crossedPages =
        (current[1] === "calendar" && prev[1] === "meals") ||
        (current[1] === "meals" && prev[1] === "calendar");
      const sameCalendarType =
        current[1] === "calendar" &&
        prev[1] === "calendar" &&
        current[2] === prev[2];
      const desktop = window.innerWidth >= 825;

      // Scroll to the top when moving between the calendar and a meal
      // page (any screen size). On desktop, also scroll on any other
      // change except month navigation within the same calendar type.
      // On mobile, never scroll otherwise — the reader keeps their place.
      if (crossedPages || (desktop && !sameCalendarType)) {
        window.scrollTo(0, 0);
      }
    },
    [location.pathname],
  );

  return children;
}

export default ScrollToTop;
