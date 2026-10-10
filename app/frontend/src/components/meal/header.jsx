import { useEffect, useRef } from "react";
import { observer } from "mobx-react-lite";
import { useNavigate } from "react-router";
import dayjs from "dayjs";
import { useStore } from "../../helpers/store_context";
import { communityNow } from "../../helpers/helpers";
import ButtonBar from "./button_bar";
import Cookie from "js-cookie";

import Icon from "../icon";

const styles = {
  // On a wide screen everything is on one line. When "history" and
  // "logout" with the person's name do not fit next to "Calendar", they
  // move to a second line, and the header grows to hold it. With a long
  // name, "logout" goes on a third line. When the header had a fixed height, "logout" was drawn below it,
  // under the meal's date box, and a tap on "logout" hit the date box
  // (#151). The second line starts at the left edge, not the right:
  // below 400px wide the page is wider than the screen (the min-width
  // on body in styles.css), so the right edge of the header is off the
  // screen.
  header: {
    display: "flex",
    flexWrap: "wrap",
    justifyContent: "space-between",
    // The .header class sets a fixed height. This replaces it.
    height: "auto",
    minHeight: "2.25rem",
  },
  // ONLINE or OFFLINE goes in the middle of the space between
  // "Calendar" and what comes next on its line: "history" on a wide
  // screen, the end of the line on a narrow one.
  status: {
    marginLeft: "auto",
    marginRight: "auto",
  },
};

const Header = observer(() => {
  const store = useStore();
  const navigate = useNavigate();
  const headerRef = useRef(null);

  // The stack of messages stops under the meal's date, so it must know
  // how tall this header is: one line, or two or three on a phone
  // (toast.css). While the header shows, the page's root element holds
  // its height.
  useEffect(function () {
    const root = document.documentElement;
    const header = headerRef.current;
    const observer = new ResizeObserver(function () {
      root.style.setProperty(
        "--meal-header-height",
        header.offsetHeight + "px",
      );
    });
    observer.observe(header);
    return function () {
      observer.disconnect();
      root.style.removeProperty("--meal-header-height");
    };
  }, []);

  // The day the Calendar button opens: the meal's day, or today while
  // the meal loads. Today is the community's, not the device's: a click
  // reads communityNow() (helpers.js).
  function calendarDay() {
    if (store.mealLoading || !store.meal) return communityNow();
    return dayjs(store.meal.date);
  }

  return (
    <header
      ref={headerRef}
      style={styles.header}
      className="header background-yellow"
    >
      <button
        onClick={() =>
          navigate(`/calendar/all/${calendarDay().format("YYYY-MM-DD")}`)
        }
        className="text-black button-link"
      >
        <h5>
          <Icon name="arrow-left" /> <strong>Calendar</strong>
        </h5>
      </button>
      {store.isOnline ? (
        <span className="online" style={styles.status}>
          ONLINE
        </span>
      ) : (
        <span className="offline" style={styles.status}>
          OFFLINE
        </span>
      )}
      <div className="flex">
        <ButtonBar />
        <button
          className="button button-link text-secondary"
          onClick={() => {
            // A cost being saved is sent and answered first, for a few
            // seconds at most: the reload would end its request, and
            // logout takes the token away (#150). If one of those saves
            // was not saved, its message is on screen, and the page
            // stays so the person can read it. The next tap goes on.
            store.finishBillsSaves().then((mayReload) => {
              if (!mayReload) return;
              store.logout();
              // Hard reload, matching login: a client-side route change
              // would leave the store and the Pusher channels alive on
              // the login page. See handleClickLogout in calendar/show.
              window.location.href = "/";
            });
          }}
        >
          logout {Cookie.get("username")}
        </button>
      </div>
    </header>
  );
});

export default Header;
