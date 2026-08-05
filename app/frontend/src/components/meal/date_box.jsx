import React, { Suspense, useEffect, useRef } from "react";
import { observer } from "mobx-react-lite";
import {
  Routes,
  Route,
  useLocation,
  useNavigate,
  useParams,
} from "react-router";
import { useStore } from "../../helpers/store_context";
import { MEAL_HISTORY_PATH } from "../../routes";
import dayjs from "dayjs";
import Modal from "react-modal";

import Icon from "../icon";

const styles = {
  main: {
    display: "flex",
    justifyContent: "center",
    alignItems: "center",
    flexDirection: "column",
    gridArea: "a1",
    border: "0.5px solid",
  },
  arrow: {
    height: "5rem",
    width: "4rem",
    display: "flex",
    flexFlow: "column",
    justifyContent: "center",
    alignItems: "center",
  },
  topDate: {
    width: "200px",
    whiteSpace: "nowrap",
  },
};

const MealHistoryShow = React.lazy(() => import("../history/show"));

Modal.setAppElement("#root");

const DateBox = observer(() => {
  const store = useStore();
  const location = useLocation();
  const navigate = useNavigate();
  const params = useParams();

  // No dependency array: run after every render, splitting on a
  // first-run flag — the exact componentDidMount/componentDidUpdate
  // pair of the class.
  const mountedRef = useRef(false);
  useEffect(function () {
    if (!mountedRef.current) {
      mountedRef.current = true;
      // Leaving the calendar: its channels must not stay live on the
      // meal page (issue #38).
      store.teardownCalendarPage();
      store.goToMeal(location.pathname.split("/")[2]);
      return;
    }

    // A URL that stops matching the loaded meal (back/forward
    // navigation) loads the right one.
    var mealId = location.pathname.split("/")[2];
    if (store.meal) {
      if (Number.parseInt(mealId, 10) !== store.meal.id) {
        store.goToMeal(mealId);
      }
    }
  });

  function handleCloseModal() {
    navigate(`${location.pathname.split("/history")[0]}`);
  }

  // A null prevId/nextId never navigates: a half-loaded meal has
  // no neighbors yet, and pushing /meals/null/edit is a stuck
  // loading page that survives refresh (issue #38).
  function prevDisabled() {
    return store.mealLoading || !store.meal || store.meal.prevId === null;
  }

  function nextDisabled() {
    return store.mealLoading || !store.meal || store.meal.nextId === null;
  }

  function handlePrevClick() {
    if (prevDisabled()) {
      return;
    }

    navigate(`/meals/${store.meal.prevId}/edit`);
  }

  function handleNextClick() {
    if (nextDisabled()) {
      return;
    }

    navigate(`/meals/${store.meal.nextId}/edit`);
  }

  function displayDate() {
    if (store.meal === null) {
      return "loading...";
    }

    if (store.meal.date === null) {
      return "loading...";
    }

    // Observable "today" from the store, not communityNow() — a
    // direct clock read is not observable, so the label would keep
    // saying "Today" after midnight on an idle tab (#36).
    var today = dayjs(store.communityToday);
    var days = dayjs(store.meal.date).diff(today, "day");

    if (days === 0) return "Today";
    if (days === -1) return "Yesterday";
    if (days === 1) return "Tomorrow";
    return dayjs(store.meal.date).from(today);
  }

  function displayTopDate() {
    if (store.meal === null) {
      return "";
    }

    if (store.meal.date === null) {
      return "";
    }

    return dayjs(store.meal.date).format("ddd, MMM Do");
  }

  return (
    <div style={styles.main} className="button-border-radius background-yellow">
      <div className="flex nowrap middle space-between">
        <div
          className="arrow"
          style={styles.arrow}
          onClick={handlePrevClick}
          onMouseDown={(e) => e.preventDefault()}
          onKeyDown={(e) => {
            if (e.key === "Enter" || e.key === " ") {
              e.preventDefault();
              handlePrevClick();
            }
          }}
          disabled={prevDisabled()}
          aria-disabled={prevDisabled()}
          role="button"
          aria-label="Previous meal"
          tabIndex={0}
        >
          <Icon name="chevron-left" size="3x" />
        </div>
        <h2 style={styles.topDate}>{displayTopDate()}</h2>
        <div
          className="arrow"
          style={styles.arrow}
          onClick={handleNextClick}
          onMouseDown={(e) => e.preventDefault()}
          onKeyDown={(e) => {
            if (e.key === "Enter" || e.key === " ") {
              e.preventDefault();
              handleNextClick();
            }
          }}
          disabled={nextDisabled()}
          aria-disabled={nextDisabled()}
          role="button"
          aria-label="Next meal"
          tabIndex={0}
        >
          <Icon name="chevron-right" size="3x" />
        </div>
      </div>
      <h3 className="text-black">{displayDate()}</h3>
      {store.meal && store.meal.reconciled ? (
        <h1 className="text-black">RECONCILED</h1>
      ) : (
        <h1
          className={
            store.meal && store.meal.closed ? "text-primary" : "text-green"
          }
        >
          {store.meal && store.meal.closed ? "CLOSED" : "OPEN"}
        </h1>
      )}
      <div>
        <Routes>
          <Route
            path={MEAL_HISTORY_PATH}
            element={
              <Modal
                isOpen={true}
                contentLabel="History Modal"
                onRequestClose={handleCloseModal}
                style={{
                  content: {
                    backgroundColor: "#CCDEEA",
                  },
                }}
              >
                <Suspense fallback={<h3>Loading...</h3>}>
                  <MealHistoryShow id={params.id} />
                </Suspense>
              </Modal>
            }
          />
        </Routes>
      </div>
    </div>
  );
});

export default DateBox;
