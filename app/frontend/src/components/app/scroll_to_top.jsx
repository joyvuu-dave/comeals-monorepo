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

      // Always scroll up when changing
      // between calendar and meal pages
      var pages = [];
      const currentPage = location.pathname.split("/");
      const prevPage = prevPathname.split("/");

      pages.push(currentPage[1]);
      pages.push(prevPage[1]);

      if (pages.indexOf("calendar") !== -1 && pages.indexOf("meals") !== -1) {
        window.scrollTo(0, 0);
        return;
      }

      // DESKTOP
      if (window.innerWidth >= 825) {
        // don't scroll up when
        // switching months
        if (
          currentPage[1] === "calendar" &&
          prevPage[1] === "calendar" &&
          currentPage[2] === prevPage[2]
        ) {
          return;
        } else {
          window.scrollTo(0, 0);
          return;
        }
      }

      // MOBILE
      if (window.innerWidth < 825) {
        return;
      }
    },
    [location.pathname],
  );

  return children;
}

export default ScrollToTop;
