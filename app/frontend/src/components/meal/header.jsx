import { observer } from "mobx-react-lite";
import { useNavigate } from "react-router";
import dayjs from "dayjs";
import { useStore } from "../../helpers/store_context";
import { communityNow } from "../../helpers/helpers";
import ButtonBar from "./button_bar";
import Cookie from "js-cookie";

import Icon from "../icon";

const styles = {
  header: {
    display: "flex",
    justifyContent: "space-between",
    height: "2.25rem",
  },
};

const Header = observer(() => {
  const store = useStore();
  const navigate = useNavigate();

  // The day the Calendar button opens: the meal's day, or today while
  // the meal loads. Today is the community's, not the device's: a click
  // reads communityNow() (helpers.js).
  function calendarDay() {
    if (store.mealLoading || !store.meal) return communityNow();
    return dayjs(store.meal.date);
  }

  return (
    <header style={styles.header} className="header background-yellow">
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
        <span className="online">ONLINE</span>
      ) : (
        <span className="offline">OFFLINE</span>
      )}
      <div className="flex">
        <ButtonBar />
        <button
          className="button button-link text-secondary"
          onClick={() => {
            store.logout();
            // Hard reload, matching login: a client-side route change
            // would leave the store and the Pusher channels alive on
            // the login page. See handleClickLogout in calendar/show.
            window.location.href = "/";
          }}
        >
          logout {Cookie.get("username")}
        </button>
      </div>
    </header>
  );
});

export default Header;
