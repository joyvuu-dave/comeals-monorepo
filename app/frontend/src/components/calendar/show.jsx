import {
  Profiler,
  memo,
  useCallback,
  useEffect,
  useRef,
  useState,
} from "react";
import { observer } from "mobx-react-lite";
import { useNavigate, useParams } from "react-router";
import { useStore } from "../../helpers/store_context";
import { communityNow } from "../../helpers/helpers";
import { mark, reportAfterPaint, profileRender } from "../../helpers/nav_trace";
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
import ConfirmModal from "../app/confirm_modal";

import WebcalLinks from "./webcal_links";
import toastStore from "../../stores/toast_store";
import { Calendar, dateFnsLocalizer } from "react-big-calendar";
import { format, parse, startOfWeek, getDay } from "date-fns";
import { enUS } from "date-fns/locale";

import Icon from "../icon";

const localizer = dateFnsLocalizer({
  format,
  parse,
  startOfWeek,
  getDay,
  locales: { "en-US": enUS },
});

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

// Click-time and getNow-time reads only. Render-time "today" must come
// from store.communityToday instead — this function is not observable,
// so a render that reads it directly goes stale after midnight (#36).
function getCommunityNow() {
  var now = communityNow();
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
  month: {
    paddingTop: "1rem",
  },
};

// Rendered as a sibling of Calendar — NOT via react-big-calendar's
// `components.toolbar` slot. This lets us:
//   1. Derive the month/year label from the URL date directly, so it
//      updates in the same commit as the URL change (no wait for
//      Calendar's ~30-40ms re-render with empty events).
//   2. Wire prev/next/today buttons to navigate() directly, bypassing
//      Calendar's onNavigate roundtrip.
//   3. Keep MemoCalendar skippable on click — Calendar's `date` prop
//      comes from the calendarDate state, which is updated in a rAF one
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
      <h2 style={styles.month}>{dayjs(dateStr).format("MMMM YYYY")}</h2>
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
          <Icon name="chevron-left" />
        </button>{" "}
        <button
          className="press"
          style={styles.chevron}
          onClick={onNext}
          aria-label="Goto Next Month"
        >
          <Icon name="chevron-right" />
        </button>
      </span>
    </div>
  );
});

Modal.setAppElement("#root");

const MainCalendar = observer(() => {
  const store = useStore();
  const params = useParams();
  const navigate = useNavigate();

  // calendarDate is a DEFERRED copy of the URL date. The toolbar
  // renders from the URL date directly (urgent — same commit as the
  // URL change). Calendar renders from this state, updated one frame
  // later in a nested rAF. Net effect: first paint after click is
  // toolbar-only (MemoCalendar sees unchanged props and skips);
  // Calendar repaints with the new month on the next frame, and events
  // fill in a frame or two after that.
  const [calendarDate, setCalendarDate] = useState(params.date);

  // The handlers below are stable (empty useCallback deps) so
  // MemoCalendar's and MonthNavHeader's shallow compares can skip
  // renders — the class got the same stability from constructor
  // binding. They read the CURRENT route and store through these refs,
  // exactly as the class read this.props at call time.
  const storeRef = useRef(store);
  storeRef.current = store;
  const paramsRef = useRef(params);
  paramsRef.current = params;
  const navigateRef = useRef(navigate);
  navigateRef.current = navigate;

  // Render-time "today" boundary for formatEvent's past-event dimming,
  // assigned every render like the class's this._todayStart.
  const todayStartRef = useRef(null);

  // Instance caches for referentially-stable Calendar props.
  const eventsCacheRef = useRef({ version: null, type: null, events: null });
  const dateCacheRef = useRef({ str: null, date: null });

  // No dependency array: run after every render, splitting on a
  // first-run flag — the exact componentDidMount/componentDidUpdate
  // pair of the class.
  const mountedRef = useRef(false);
  const prevRouteRef = useRef({ type: params.type, date: params.date });
  useEffect(function () {
    if (!mountedRef.current) {
      mountedRef.current = true;
      // Leaving a meal: its channel must not stay live on the
      // calendar, and a late meal response must find no meal to
      // write to (issue #38).
      storeRef.current.teardownMealPage();
      storeRef.current.goToMonth(paramsRef.current.date);
      // Prime the hosts cache while the month is loading. The user is
      // about to open a Guest Room or Common House modal; warming the
      // cache now turns the *first* open into a cache hit too, not just
      // the second+ open. Fire-and-forget: ensureHosts dedupes in-flight
      // requests and swallows its own errors via handleAxiosError.
      storeRef.current.ensureHosts();
      return;
    }

    const prev = prevRouteRef.current;
    const current = {
      type: paramsRef.current.type,
      date: paramsRef.current.date,
    };
    prevRouteRef.current = current;
    if (prev.type !== current.type || prev.date !== current.date) {
      mark("componentDidUpdate");
      // Measure the "toolbar paint" — the fast feedback frame where
      // the new month/year label reaches the screen. reportAfterPaint
      // lands `painted` via 2x rAF, which now reflects the
      // toolbar-only first paint (MemoCalendar is skipped on this
      // commit because calendarDate and events are unchanged).
      reportAfterPaint("toolbar-" + current.date);
      // Defer every state change that would cause a Calendar re-render
      // to the SECOND frame after commit. Nested rAF is required:
      // a single rAF fires in the same frame as reportAfterPaint's
      // rAFs, which means the work we do in it lands before the first
      // paint. Going two frames deep lets the browser paint the
      // toolbar-only commit first, then we sync calendarDate
      // (Calendar re-renders with new date) and load data.
      requestAnimationFrame(function () {
        requestAnimationFrame(function () {
          // Read the URL date at rAF time, not at effect time —
          // rapid clicks may have advanced the URL further since
          // this effect fired.
          var latestDate = paramsRef.current.date;
          storeRef.current.clearCalendarEvents();
          setCalendarDate(latestDate);
          storeRef.current.goToMonth(latestDate);
        });
      });
    }
  });

  // The discard gate (ADR 0006). Forms in the modal report unsaved
  // changes through setModalDirty; every way out of the modal — a
  // click outside it, Escape, the X — runs through handleCloseModal.
  // A clean form closes at once. A dirty one gets one question:
  // "Discard your changes?" Forms that just saved report themselves
  // clean first, so Create/Update/Delete close without asking.
  //
  // A ref, not state: the flag is only read at close time, and a
  // keystroke in a form must not re-render the calendar.
  const modalDirtyRef = useRef(false);
  const [discardConfirmOpen, setDiscardConfirmOpen] = useState(false);

  const setModalDirty = useCallback(function (value) {
    modalDirtyRef.current = value;
  }, []);

  const closeModal = useCallback(function () {
    toastStore.clearAll();
    modalDirtyRef.current = false;
    setDiscardConfirmOpen(false);
    navigateRef.current(
      `/calendar/${paramsRef.current.type}/${paramsRef.current.date}`,
    );
  }, []);

  const handleCloseModal = useCallback(
    function () {
      if (modalDirtyRef.current) {
        setDiscardConfirmOpen(true);
        return;
      }
      closeModal();
    },
    [closeModal],
  );

  const handleDiscardConfirm = useCallback(
    function () {
      closeModal();
    },
    [closeModal],
  );

  const handleDiscardCancel = useCallback(function () {
    setDiscardConfirmOpen(false);
  }, []);

  const handleClickLogout = useCallback(function () {
    storeRef.current.logout();
    // Hard reload, matching login. A client-side route change would
    // leave the store and the Pusher channels alive on the login
    // page; the next broadcast would fire an unauthenticated fetch
    // and raise the "signed out" banner. A reload resets everything.
    window.location.href = "/";
  }, []);

  const formatEvent = useCallback(function (event) {
    var eventStyles = { style: {} };

    if (
      event.start < todayStartRef.current &&
      typeof event.url !== "undefined"
    ) {
      eventStyles.style["opacity"] = "0.6";
    }

    eventStyles.style["backgroundColor"] = event.color;
    return eventStyles;
  }, []);

  // Safety net for any Calendar-initiated navigation (e.g. keyboard).
  // Primary nav is driven by handlePrev/handleNext/handleToday from
  // the external toolbar. No clearCalendarEvents here — we want the
  // first commit after a click to leave Calendar untouched so memo
  // skips it; events clear is deferred to the nested rAF in the
  // route-change effect.
  const handleNavigate = useCallback(function (event) {
    var newDate = dayjs(event).format("YYYY-MM-DD");
    if (newDate !== paramsRef.current.date) {
      navigateRef.current(`/calendar/${paramsRef.current.type}/${newDate}`);
    }
  }, []);

  const handlePrev = useCallback(function () {
    mark("click");
    var newDate = dayjs(paramsRef.current.date)
      .subtract(1, "month")
      .format("YYYY-MM-DD");
    navigateRef.current(`/calendar/${paramsRef.current.type}/${newDate}`);
  }, []);

  const handleNext = useCallback(function () {
    mark("click");
    var newDate = dayjs(paramsRef.current.date)
      .add(1, "month")
      .format("YYYY-MM-DD");
    navigateRef.current(`/calendar/${paramsRef.current.type}/${newDate}`);
  }, []);

  const handleToday = useCallback(function () {
    mark("click");
    var newDate = dayjs(getCommunityNow()).format("YYYY-MM-DD");
    if (newDate !== paramsRef.current.date) {
      navigateRef.current(`/calendar/${paramsRef.current.type}/${newDate}`);
    }
  }, []);

  const handleSelectEvent = useCallback(function (event) {
    if (event.url) {
      navigateRef.current(event.url);
      return false;
    }
  }, []);

  // Return a referentially-stable events array so MemoCalendar can
  // skip re-rendering when the store hasn't actually changed. We cache
  // a single slice() keyed on (version, type); the store bumps
  // calendarEventsVersion whenever the underlying array mutates.
  function filterEvents() {
    var v = store.calendarEventsVersion;
    var type = params.type;
    var cache = eventsCacheRef.current;
    if (cache.version !== v || cache.type !== type) {
      cache.version = v;
      cache.type = type;
      // calendarEvents contains frozen (plain JS) objects —
      // slice() copies the array without deep-cloning items.
      cache.events = type === "all" ? store.calendarEvents.slice() : [];
    }
    return cache.events;
  }

  // Same idea as filterEvents: cache the Date instance keyed on the
  // date string so MemoCalendar's shallow prop compare doesn't see a
  // fresh `new Date(...)` on every MainCalendar render. Sourced from
  // calendarDate (deferred), NOT the URL date — so clicking prev/next
  // doesn't invalidate Calendar's memo on the first commit.
  function getCalendarDate() {
    var cache = dateCacheRef.current;
    if (cache.str !== calendarDate) {
      cache.str = calendarDate;
      cache.date = dayjs(calendarDate).toDate();
    }
    return cache.date;
  }

  function renderModal() {
    if (typeof params.modal === "undefined") {
      return null;
    }

    // NEW RESOURCE
    if (params.view === "new") {
      switch (params.modal) {
        case "guest_room_reservations":
        case "guest-room-reservations":
          return (
            <GuestRoomReservationsNew
              handleCloseModal={handleCloseModal}
              setDirty={setModalDirty}
            />
          );

        case "common_house_reservations":
        case "common-house-reservations":
          return (
            <CommonHouseReservationsNew
              handleCloseModal={handleCloseModal}
              setDirty={setModalDirty}
            />
          );

        case "events":
          return (
            <EventsNew
              handleCloseModal={handleCloseModal}
              setDirty={setModalDirty}
            />
          );

        default:
          return null;
      }
    }

    // EDIT RESOURCE
    if (params.view === "edit") {
      switch (params.modal) {
        case "guest_room_reservations":
        case "guest-room-reservations":
          return (
            <GuestRoomReservationsEdit
              eventId={params.id}
              handleCloseModal={handleCloseModal}
              setDirty={setModalDirty}
            />
          );

        case "common_house_reservations":
        case "common-house-reservations":
          return (
            <CommonHouseReservationsEdit
              eventId={params.id}
              handleCloseModal={handleCloseModal}
              setDirty={setModalDirty}
            />
          );

        case "events":
          return (
            <EventsEdit
              eventId={params.id}
              handleCloseModal={handleCloseModal}
              setDirty={setModalDirty}
            />
          );

        default:
          return null;
      }
    }

    // SHOW RESOURCE
    if (params.view === "show") {
      switch (params.modal) {
        case "rotations":
          return (
            <RotationsShow id={params.id} handleCloseModal={handleCloseModal} />
          );

        default:
          return null;
      }
    }
  }

  // The observable "today" (community timezone, "YYYY-MM-DD").
  // Reading it here subscribes this render to the store's midnight
  // rollover, so an idle tab repaints when the day changes. Also
  // the "today" boundary for formatEvent's past-event dimming.
  var communityToday = store.communityToday;
  todayStartRef.current = dayjs(communityToday).toDate();
  return (
    <div className="offwhite">
      <header className="header flex space-between">
        <h5 className="pad-xs">{dayjs(communityToday).format("ddd MMM Do")}</h5>
        {store.isOnline ? (
          <span className="online">ONLINE</span>
        ) : (
          <span className="offline">OFFLINE</span>
        )}
        <span>
          <button
            onClick={handleClickLogout}
            className="button-link text-secondary"
          >
            {`logout ${Cookie.get("username")}`}
          </button>
        </span>
      </header>
      <div style={styles.main} className="responsive-calendar">
        <SideBar />
        <div style={{ height: 2000, marginRight: 15 }}>
          <MonthNavHeader
            dateStr={params.date}
            onPrev={handlePrev}
            onNext={handleNext}
            onToday={handleToday}
          />
          <Profiler id="Calendar" onRender={profileRender}>
            {/* communityToday is not a react-big-calendar prop.
                Calendar ignores it; it exists to break the memo's
                shallow compare once at midnight, so getNow and
                eventPropGetter re-run with the new day. Without
                it the header would show the new date while the
                grid still highlighted yesterday. */}
            <MemoCalendar
              communityToday={communityToday}
              localizer={localizer}
              date={getCalendarDate()}
              defaultView="month"
              eventPropGetter={formatEvent}
              events={filterEvents()}
              className="calendar"
              onNavigate={handleNavigate}
              onSelectEvent={handleSelectEvent}
              views={VIEWS}
              getNow={getCommunityNow}
              toolbar={false}
            />
          </Profiler>
          <WebcalLinks />
        </div>
      </div>
      <Modal
        isOpen={typeof params.modal !== "undefined"}
        contentLabel="Event Modal"
        onRequestClose={handleCloseModal}
        // react-modal's own overlay-click detection breaks after a day
        // is picked: react-day-picker stops the click's propagation
        // (its handleDayClick calls e.stopPropagation()), so the click
        // never bubbles to the overlay — and the overlay's click
        // handler is the only place react-modal resets its internal
        // shouldClose flag. The flag sticks at false and the next
        // click outside the form is silently eaten (one dead click,
        // then the gate fires). So the built-in path is off, and the
        // overlay closes on its own mousedown instead: a press that
        // starts on the overlay itself is a close request, and no
        // widget inside the form can stop a mousedown it never sees.
        // Escape still arrives through onRequestClose.
        shouldCloseOnOverlayClick={false}
        overlayElement={(props, contentElement) => (
          <div
            {...props}
            onMouseDown={(e) => {
              if (props.onMouseDown) props.onMouseDown(e);
              if (e.target === e.currentTarget) {
                handleCloseModal();
              }
            }}
          >
            {contentElement}
          </div>
        )}
        style={{
          content: {
            backgroundColor: "#CCDEEA",
          },
        }}
      >
        {renderModal()}
      </Modal>
      <ConfirmModal
        isOpen={discardConfirmOpen}
        message="Discard your changes?"
        cancelLabel="Keep editing"
        confirmLabel="Discard"
        armMs={400}
        onCancel={handleDiscardCancel}
        onConfirm={handleDiscardConfirm}
      />
    </div>
  );
});

export default MainCalendar;
