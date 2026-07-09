import React, { Component, Suspense } from "react";
import { inject, observer } from "mobx-react";
import { Routes, Route } from "react-router-dom";
import { withRouter } from "../../helpers/with_router";
import dayjs from "dayjs";
import Modal from "react-modal";

import { FontAwesomeIcon } from "@fortawesome/react-fontawesome";
import { faChevronLeft } from "@fortawesome/free-solid-svg-icons";
import { faChevronRight } from "@fortawesome/free-solid-svg-icons";

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
const DateBox = inject("store")(
  withRouter(
    observer(
      class DateBox extends Component {
        constructor(props) {
          super(props);

          this.handlePrevClick = this.handlePrevClick.bind(this);
          this.handleNextClick = this.handleNextClick.bind(this);
          this.handleCloseModal = this.handleCloseModal.bind(this);
        }

        componentDidUpdate() {
          var pathNameArray = this.props.location.pathname.split("/");
          var mealId = pathNameArray[2];

          if (this.props.store.meal) {
            if (Number.parseInt(mealId, 10) !== this.props.store.meal.id) {
              this.props.store.goToMeal(mealId);
            }
          }
        }

        componentDidMount() {
          // Leaving the calendar: its channels must not stay live on the
          // meal page (issue #38).
          this.props.store.teardownCalendarPage();
          this.props.store.goToMeal(this.props.location.pathname.split("/")[2]);
        }

        handleCloseModal() {
          this.props.history.push(
            `${this.props.match.url.split("/history")[0]}`,
          );
        }

        // A null prevId/nextId never navigates: a half-loaded meal has
        // no neighbors yet, and pushing /meals/null/edit is a stuck
        // loading page that survives refresh (issue #38).
        handlePrevClick() {
          if (this.prevDisabled()) {
            return;
          }

          this.props.history.push(
            `/meals/${this.props.store.meal.prevId}/edit`,
          );
        }

        handleNextClick() {
          if (this.nextDisabled()) {
            return;
          }

          this.props.history.push(
            `/meals/${this.props.store.meal.nextId}/edit`,
          );
        }

        prevDisabled() {
          const store = this.props.store;
          return store.mealLoading || !store.meal || store.meal.prevId === null;
        }

        nextDisabled() {
          const store = this.props.store;
          return store.mealLoading || !store.meal || store.meal.nextId === null;
        }

        displayDate() {
          if (this.props.store.meal === null) {
            return "loading...";
          }

          if (this.props.store.meal.date === null) {
            return "loading...";
          }

          // Observable "today" from the store, not communityNow() — a
          // direct clock read is not observable, so the label would keep
          // saying "Today" after midnight on an idle tab (#36).
          var today = dayjs(this.props.store.communityToday);
          var days = dayjs(this.props.store.meal.date).diff(today, "day");

          if (days === 0) return "Today";
          if (days === -1) return "Yesterday";
          if (days === 1) return "Tomorrow";
          return dayjs(this.props.store.meal.date).from(today);
        }

        displayTopDate() {
          if (this.props.store.meal === null) {
            return "";
          }

          if (this.props.store.meal.date === null) {
            return "";
          }

          return dayjs(this.props.store.meal.date).format("ddd, MMM Do");
        }

        render() {
          return (
            <div
              style={styles.main}
              className="button-border-radius background-yellow"
            >
              <div className="flex nowrap middle space-between">
                <div
                  className="arrow"
                  style={styles.arrow}
                  onClick={this.handlePrevClick}
                  onMouseDown={(e) => e.preventDefault()}
                  onKeyDown={(e) => {
                    if (e.key === "Enter" || e.key === " ") {
                      e.preventDefault();
                      this.handlePrevClick();
                    }
                  }}
                  disabled={this.prevDisabled()}
                  aria-disabled={this.prevDisabled()}
                  role="button"
                  aria-label="Previous meal"
                  tabIndex={0}
                >
                  <FontAwesomeIcon icon={faChevronLeft} size="3x" />
                </div>
                <h2 style={styles.topDate}>{this.displayTopDate()}</h2>
                <div
                  className="arrow"
                  style={styles.arrow}
                  onClick={this.handleNextClick}
                  onMouseDown={(e) => e.preventDefault()}
                  onKeyDown={(e) => {
                    if (e.key === "Enter" || e.key === " ") {
                      e.preventDefault();
                      this.handleNextClick();
                    }
                  }}
                  disabled={this.nextDisabled()}
                  aria-disabled={this.nextDisabled()}
                  role="button"
                  aria-label="Next meal"
                  tabIndex={0}
                >
                  <FontAwesomeIcon icon={faChevronRight} size="3x" />
                </div>
              </div>
              <h3 className="text-black">{this.displayDate()}</h3>
              {this.props.store.meal && this.props.store.meal.reconciled ? (
                <h1 className="text-black">RECONCILED</h1>
              ) : (
                <h1
                  className={
                    this.props.store.meal && this.props.store.meal.closed
                      ? "text-primary"
                      : "text-green"
                  }
                >
                  {this.props.store.meal && this.props.store.meal.closed
                    ? "CLOSED"
                    : "OPEN"}
                </h1>
              )}
              <div>
                <Routes>
                  <Route
                    path="history/*"
                    element={
                      <Modal
                        isOpen={true}
                        contentLabel="History Modal"
                        onRequestClose={this.handleCloseModal}
                        style={{
                          content: {
                            backgroundColor: "#CCDEEA",
                          },
                        }}
                      >
                        <Suspense fallback={<h3>Loading...</h3>}>
                          <MealHistoryShow id={this.props.match.params.id} />
                        </Suspense>
                      </Modal>
                    }
                  />
                </Routes>
              </div>
            </div>
          );
        }
      },
    ),
  ),
);

export default DateBox;
