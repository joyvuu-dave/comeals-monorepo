import { Component, Profiler, memo } from "react";
import { inject, observer } from "mobx-react";
import { withRouter } from "../../helpers/with_router";
import { TIMEZONE } from "../../helpers/helpers";
import {
  mark,
  reportAfterPaint,
  profileRender,
  logEvent,
} from "../../helpers/nav_trace";
import SideBar from "./side_bar";

import Cookie from "js-cookie";
import dayjs from "dayjs";

import Modal from "react-modal";
import GuestRoomReservationsNew from "../guest_room_reservations/new";
import CommonHouseReservationsNew from "../common_house_reservations/new";
import EventsNew from "../events/new";
import GuestRoomReservationsEdit from "../guest_room_reservations/edit";
import CommonHouseReservationsEdit from "../common_house_reservations/edit";
import EventsEdit from "../events/edit";
import RotationsShow from "../rotations/show";

import WebcalLinks from "./webcal_links";
import toastStore from "../../stores/toast_store";
import { Calendar, dayjsLocalizer } from "react-big-calendar";

import { FontAwesomeIcon } from "@fortawesome/react-fontawesome";
import { faChevronLeft } from "@fortawesome/free-solid-svg-icons";
import { faChevronRight } from "@fortawesome/free-solid-svg-icons";

const localizer = dayjsLocalizer(dayjs);

// Module-level constants so react-big-calendar's prop identity stays stable
// across MainCalendar renders. An inline `views={["month"]}` literal would
// be a new array on every render and defeat MemoCalendar's shallow compare.
const VIEWS = ["month"];

// react-big-calendar's internal render is O(events) (~3.5ms/event). Wrapping
// it in React.memo lets us skip that work when MainCalendar re-renders for
// reasons unrelated to the calendar (notably: modal open/close, which pushes
// a new route and triggers two MainCalendar renders per transition). The
// parent passes referentially-stable `date` and `events` props so this memo
// actually bites.
const MemoCalendar = memo(Calendar);

function getPacificNow() {
  var now = dayjs().tz(TIMEZONE);
  return new Date(
    now.year(),
    now.month(),
    now.date(),
    now.hour(),
    now.minute(),
  );
}

const styles = {
  main: {
    display: "flex",
    justifyContent: "space-between",
    flexWrap: "nowrap",
  },
  chevron: {
    backgroundColor: "#444",
    border: "1px solid black",
    opacity: "0.75",
    width: "4rem",
    marginTop: "1rem",
  },
};

// Rendered as a sibling of Calendar — NOT via react-big-calendar's
// `components.toolbar` slot. This lets us:
//   1. Derive the month/year label from `match.params.date` directly,
//      so it updates in the same commit as the URL change (no wait for
//      Calendar's ~30-40ms re-render with empty events).
//   2. Wire prev/next/today buttons to history.push directly, bypassing
//      Calendar's onNavigate roundtrip.
//   3. Keep MemoCalendar skippable on click — Calendar's `date` prop
//      comes from this.state.calendarDate, which is updated in a rAF one
//      frame later, so the first commit is toolbar-only.
//
// Wrapped in memo so unrelated MainCalendar re-renders (modal open/close)
// don't bounce the toolbar.
const MonthNavHeader = memo(function MonthNavHeader({
  dateStr,
  onPrev,
  onNext,
  onToday,
}) {
  return (
    <div style={styles.main}>
      <h2>{dayjs(dateStr).format("MMMM YYYY")}</h2>
      <span style={styles.main}>
        <button className="mar-sm press" onClick={onToday}>
          today
        </button>
        <button
          className="press"
          style={styles.chevron}
          onClick={onPrev}
          aria-label="Goto Last Month"
        >
          <FontAwesomeIcon icon={faChevronLeft} />
        </button>{" "}
        <button
          className="press"
          style={styles.chevron}
          onClick={onNext}
          aria-label="Goto Next Month"
        >
          <FontAwesomeIcon icon={faChevronRight} />
        </button>
      </span>
    </div>
  );
});

Modal.setAppElement("#root");
const MainCalendar = inject("store")(
  withRouter(
    observer(
      class MainCalendar extends Component {
        constructor(props) {
          super(props);

          // calendarDate is a DEFERRED copy of match.params.date. The
          // toolbar renders from match.params.date directly (urgent — same
          // commit as the URL change). Calendar renders from this state,
          // updated one frame later in a nested rAF. Net effect: first
          // paint after click is toolbar-only (MemoCalendar sees unchanged
          // props and skips); Calendar repaints with the new month on the
          // next frame, and events fill in a frame or two after that.
          this.state = { calendarDate: props.match.params.date };

          this.handleCloseModal = this.handleCloseModal.bind(this);

          this.handleNavigate = this.handleNavigate.bind(this);
          this.handleSelectEvent = this.handleSelectEvent.bind(this);
          this.filterEvents = this.filterEvents.bind(this);
          this.formatEvent = this.formatEvent.bind(this);
          this.handleClickLogout = this.handleClickLogout.bind(this);
          this.handlePrev = this.handlePrev.bind(this);
          this.handleNext = this.handleNext.bind(this);
          this.handleToday = this.handleToday.bind(this);
        }

        componentDidMount() {
          this.props.store.goToMonth(this.props.match.params.date);
          // Prime the hosts cache while the month is loading. The user is
          // about to open a Guest Room or Common House modal; warming the
          // cache now turns the *first* open into a cache hit too, not just
          // the second+ open. Fire-and-forget: ensureHosts dedupes in-flight
          // requests and swallows its own errors via handleAxiosError.
          this.props.store.ensureHosts();
        }

        componentDidUpdate(prevProps) {
          if (
            prevProps.match.params.type !== this.props.match.params.type ||
            prevProps.match.params.date !== this.props.match.params.date
          ) {
            mark("componentDidUpdate");
            // Measure the "toolbar paint" — the fast feedback frame where
            // the new month/year label reaches the screen. reportAfterPaint
            // lands `painted` via 2x rAF, which now reflects the
            // toolbar-only first paint (MemoCalendar is skipped on this
            // commit because state.calendarDate and events are unchanged).
            reportAfterPaint("toolbar-" + this.props.match.params.date);
            // Defer every state change that would cause a Calendar re-render
            // to the SECOND frame after commit. Nested rAF is required:
            // a single rAF fires in the same frame as reportAfterPaint's
            // rAFs, which means the work we do in it lands before the first
            // paint. Going two frames deep lets the browser paint the
            // toolbar-only commit first, then we sync state.calendarDate
            // (Calendar re-renders with new date) and load data.
            var self = this;
            requestAnimationFrame(function () {
              requestAnimationFrame(function () {
                // Read match.params.date at rAF time, not at cDU time —
                // rapid clicks may have advanced the URL further since
                // this cDU fired.
                var latestDate = self.props.match.params.date;
                self.props.store.clearCalendarEvents();
                self.setState({ calendarDate: latestDate });
                self.props.store.goToMonth(latestDate);
              });
            });
          }
        }

        renderModal() {
          if (typeof this.props.match.params.modal === "undefined") {
            return null;
          }

          // NEW RESOURCE
          if (this.props.match.params.view === "new") {
            switch (this.props.match.params.modal) {
              case "guest_room_reservations":
              case "guest-room-reservations":
                return (
                  <GuestRoomReservationsNew
                    handleCloseModal={this.handleCloseModal}
                    match={this.props.match}
                  />
                );

              case "common_house_reservations":
              case "common-house-reservations":
                return (
                  <CommonHouseReservationsNew
                    handleCloseModal={this.handleCloseModal}
                    match={this.props.match}
                  />
                );

              case "events":
                return (
                  <EventsNew
                    handleCloseModal={this.handleCloseModal}
                    match={this.props.match}
                  />
                );

              default:
                return null;
            }
          }

          // EDIT RESOURCE
          if (this.props.match.params.view === "edit") {
            switch (this.props.match.params.modal) {
              case "guest_room_reservations":
              case "guest-room-reservations":
                return (
                  <GuestRoomReservationsEdit
                    eventId={this.props.match.params.id}
                    handleCloseModal={this.handleCloseModal}
                  />
                );

              case "common_house_reservations":
              case "common-house-reservations":
                return (
                  <CommonHouseReservationsEdit
                    eventId={this.props.match.params.id}
                    handleCloseModal={this.handleCloseModal}
                  />
                );

              case "events":
                return (
                  <EventsEdit
                    eventId={this.props.match.params.id}
                    handleCloseModal={this.handleCloseModal}
                  />
                );

              default:
                return null;
            }
          }

          // SHOW RESOURCE
          if (this.props.match.params.view === "show") {
            switch (this.props.match.params.modal) {
              case "rotations":
                return (
                  <RotationsShow
                    id={this.props.match.params.id}
                    handleCloseModal={this.handleCloseModal}
                  />
                );

              default:
                return null;
            }
          }
        }

        handleCloseModal() {
          toastStore.clearAll();
          this.props.history.push(
            `/calendar/${this.props.match.params.type}/${
              this.props.match.params.date
            }`,
          );
        }

        handleClickLogout() {
          this.props.store.logout();
          this.props.history.push("/");
        }

        formatEvent(event) {
          var styles = { style: {} };

          if (
            event.start < this._todayStart &&
            typeof event.url !== "undefined"
          ) {
            styles.style["opacity"] = "0.6";
          }

          styles.style["backgroundColor"] = event.color;
          return styles;
        }

        render() {
          // Compute "today" boundary once per render for formatEvent
          var now = getPacificNow();
          this._todayStart = new Date(
            now.getFullYear(),
            now.getMonth(),
            now.getDate(),
          );
          logEvent("MainCalendar-render", {
            path: this.props.location.pathname,
            isOnline: this.props.store.isOnline,
            eventsLen: this.props.store.calendarEvents.length,
          });
          return (
            <div className="offwhite">
              <header className="header flex space-between">
                <h5 className="pad-xs">
                  {dayjs(getPacificNow()).format("ddd MMM Do")}
                </h5>
                {this.props.store.isOnline ? (
                  <span className="online">ONLINE</span>
                ) : (
                  <span className="offline">OFFLINE</span>
                )}
                <span>
                  <button
                    onClick={this.handleClickLogout}
                    className="button-link text-secondary"
                  >
                    {`logout ${Cookie.get("username")}`}
                  </button>
                </span>
              </header>
              <div style={styles.main} className="responsive-calendar">
                <SideBar
                  match={this.props.match}
                  history={this.props.history}
                  location={this.props.location}
                />
                <div style={{ height: 2000, marginRight: 15 }}>
                  <MonthNavHeader
                    dateStr={this.props.match.params.date}
                    onPrev={this.handlePrev}
                    onNext={this.handleNext}
                    onToday={this.handleToday}
                  />
                  <Profiler id="Calendar" onRender={profileRender}>
                    <MemoCalendar
                      localizer={localizer}
                      date={this.getCalendarDate()}
                      defaultView="month"
                      eventPropGetter={this.formatEvent}
                      events={this.filterEvents()}
                      className="calendar"
                      onNavigate={this.handleNavigate}
                      onSelectEvent={this.handleSelectEvent}
                      views={VIEWS}
                      getNow={getPacificNow}
                      toolbar={false}
                    />
                  </Profiler>
                  <WebcalLinks />
                </div>
              </div>
              <Modal
                isOpen={typeof this.props.match.params.modal !== "undefined"}
                contentLabel="Event Modal"
                onRequestClose={this.handleCloseModal}
                style={{
                  content: {
                    backgroundColor: "#CCDEEA",
                  },
                }}
              >
                {this.renderModal()}
              </Modal>
            </div>
          );
        }

        // Safety net for any Calendar-initiated navigation (e.g. keyboard).
        // Primary nav is driven by handlePrev/handleNext/handleToday from
        // the external toolbar. No clearCalendarEvents here — we want the
        // first commit after a click to leave Calendar untouched so memo
        // skips it; events clear is deferred to the nested rAF in cDU.
        handleNavigate(event) {
          var newDate = dayjs(event).format("YYYY-MM-DD");
          if (newDate !== this.props.match.params.date) {
            this.props.history.push(
              `/calendar/${this.props.match.params.type}/${newDate}`,
            );
          }
        }

        handlePrev() {
          mark("click");
          var newDate = dayjs(this.props.match.params.date)
            .subtract(1, "month")
            .format("YYYY-MM-DD");
          this.props.history.push(
            `/calendar/${this.props.match.params.type}/${newDate}`,
          );
        }

        handleNext() {
          mark("click");
          var newDate = dayjs(this.props.match.params.date)
            .add(1, "month")
            .format("YYYY-MM-DD");
          this.props.history.push(
            `/calendar/${this.props.match.params.type}/${newDate}`,
          );
        }

        handleToday() {
          mark("click");
          var newDate = dayjs(getPacificNow()).format("YYYY-MM-DD");
          if (newDate !== this.props.match.params.date) {
            this.props.history.push(
              `/calendar/${this.props.match.params.type}/${newDate}`,
            );
          }
        }

        handleSelectEvent(event) {
          if (event.url) {
            this.props.history.push(event.url);
            return false;
          }
        }

        // Return a referentially-stable events array so MemoCalendar can
        // skip re-rendering when the store hasn't actually changed. We cache
        // a single slice() keyed on (version, type); the store bumps
        // calendarEventsVersion whenever the underlying array mutates.
        filterEvents() {
          var store = this.props.store;
          var v = store.calendarEventsVersion;
          var type = this.props.match.params.type;
          if (this._eventsVersion !== v || this._eventsType !== type) {
            this._eventsVersion = v;
            this._eventsType = type;
            // calendarEvents contains frozen (plain JS) objects —
            // slice() copies the array without deep-cloning items.
            this._filteredEvents =
              type === "all" ? store.calendarEvents.slice() : [];
          }
          return this._filteredEvents;
        }

        // Same idea as filterEvents: cache the Date instance keyed on the
        // date string so MemoCalendar's shallow prop compare doesn't see a
        // fresh `new Date(...)` on every MainCalendar render. Sourced from
        // state.calendarDate (deferred), NOT match.params.date — so clicking
        // prev/next doesn't invalidate Calendar's memo on the first commit.
        getCalendarDate() {
          var dateStr = this.state.calendarDate;
          if (this._lastDateStr !== dateStr) {
            this._lastDateStr = dateStr;
            this._cachedDate = dayjs(dateStr).toDate();
          }
          return this._cachedDate;
        }
      },
    ),
  ),
);

export default MainCalendar;
