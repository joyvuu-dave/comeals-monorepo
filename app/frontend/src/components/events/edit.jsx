import { useEffect, useRef, useState } from "react";
import axios from "axios";
import dayjs from "dayjs";
import utc from "dayjs/plugin/utc";
import timezone from "dayjs/plugin/timezone";
import DayPickerInputWrapper from "../common/day_picker_input";
import { useStore } from "../../helpers/store_context";
import { generateTimes, toCommunityDayjs } from "../../helpers/helpers";
import handleAxiosError from "../../helpers/handle_axios_error";
import { FontAwesomeIcon } from "@fortawesome/react-fontawesome";
import { faTimes } from "@fortawesome/free-solid-svg-icons";
import ConfirmModal from "../app/confirm_modal";

dayjs.extend(utc);
dayjs.extend(timezone);

// Render the full form from the first frame; the per-event fetch hydrates
// the inputs when it returns. There's no hosts dependency here (events
// don't belong to a resident) so `data-populated` simply tracks the event
// payload's arrival.
function EventsEdit({ eventId, handleCloseModal }) {
  const store = useStore();

  const [loaded, setLoaded] = useState(false);
  const [event, setEvent] = useState({});
  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [day, setDay] = useState("");
  const [startTime, setStartTime] = useState("");
  const [endTime, setEndTime] = useState("");
  const [allDay, setAllDay] = useState(false);
  const [loadingAction, setLoadingAction] = useState(null);
  const [confirmDeleteOpen, setConfirmDeleteOpen] = useState(false);

  // The requests outlive a closed modal; the flag keeps their
  // callbacks from setting state after unmount, like the class's
  // _isMounted.
  const mountedRef = useRef(true);

  useEffect(
    function () {
      mountedRef.current = true;
      axios
        .get(`/api/v1/events/${eventId}`)
        .then(function (response) {
          if (!mountedRef.current) return;
          if (response.status === 200) {
            var evt = response.data;
            var sd = toCommunityDayjs(evt.start_date);
            setEvent(evt);
            setLoaded(true);
            setTitle(evt.title);
            setDescription(evt.description);
            setDay(new Date(sd.year(), sd.month(), sd.date()));
            setStartTime(
              `${toCommunityDayjs(evt.start_date)
                .hour()
                .toString()
                .padStart(2, "0")}:${toCommunityDayjs(evt.start_date)
                .minute()
                .toString()
                .padStart(2, "0")}`,
            );
            setEndTime(
              evt.end_date
                ? `${toCommunityDayjs(evt.end_date)
                    .hour()
                    .toString()
                    .padStart(2, "0")}:${toCommunityDayjs(evt.end_date)
                    .minute()
                    .toString()
                    .padStart(2, "0")}`
                : "",
            );
            setAllDay(evt.allday);
          }
        })
        .catch(function (error) {
          handleAxiosError(error, { silent: true });
        });

      return function () {
        mountedRef.current = false;
      };
    },
    [eventId],
  );

  function handleSubmit(e) {
    e.preventDefault();
    setLoadingAction("submit");
    axios
      .patch(`/api/v1/events/${eventId}/update`, {
        title: title,
        description: description,
        start_year: day && new Date(day).getFullYear(),
        start_month: day && new Date(day).getMonth() + 1,
        start_day: day && new Date(day).getDate(),
        start_hours: startTime && startTime.split(":")[0],
        start_minutes: startTime && startTime.split(":")[1],
        end_hours: endTime && endTime.split(":")[0],
        end_minutes: endTime && endTime.split(":")[1],
        all_day: allDay,
      })
      .then(function (response) {
        if (!mountedRef.current) return;
        setLoadingAction(null);
        if (response.status === 200) {
          // The client that knows, invalidates (issue #37). Both months:
          // the edit may have moved the event out of its old month.
          store.invalidateMonthForDate(event.start_date);
          store.invalidateMonthForDate(day);
          handleCloseModal();
        }
      })
      .catch(function (error) {
        if (!mountedRef.current) return;
        setLoadingAction(null);
        handleAxiosError(error);
      });
  }

  function handleDeleteClick() {
    if (loadingAction) return;
    setConfirmDeleteOpen(true);
  }

  function handleDeleteConfirm() {
    setConfirmDeleteOpen(false);
    setLoadingAction("delete");
    axios
      .delete(`/api/v1/events/${eventId}/delete`)
      .then(function (response) {
        if (!mountedRef.current) return;
        setLoadingAction(null);
        if (response.status === 200) {
          // The client that knows, invalidates (issue #37).
          store.invalidateMonthForDate(event.start_date);
          handleCloseModal();
        }
      })
      .catch(function (error) {
        if (!mountedRef.current) return;
        setLoadingAction(null);
        handleAxiosError(error);
      });
  }

  function handleDeleteCancel() {
    setConfirmDeleteOpen(false);
  }

  function handleDayChange(val) {
    setDay(val);
  }

  const disabled = loadingAction !== null || !loaded;
  return (
    <div>
      <div className="flex">
        <h2>Event</h2>
        <button
          onClick={handleDeleteClick}
          type="button"
          className={
            loadingAction === "delete"
              ? "mar-l-md button-warning button-loader"
              : "mar-l-md button-warning"
          }
          disabled={disabled}
        >
          Delete
        </button>
        <FontAwesomeIcon
          icon={faTimes}
          size="2x"
          className="close-button"
          onClick={handleCloseModal}
          onKeyDown={(e) => {
            if (e.key === "Enter" || e.key === " ") {
              e.preventDefault();
              handleCloseModal();
            }
          }}
          role="button"
          aria-label="Close"
          tabIndex={0}
        />
      </div>
      <fieldset data-populated={loaded ? "true" : undefined}>
        <legend>Edit</legend>
        <form onSubmit={handleSubmit}>
          <label htmlFor="event-edit-title">Title</label>
          <input
            id="event-edit-title"
            type="text"
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            disabled={disabled}
          />
          <br />
          <label htmlFor="event-edit-description">Description</label>
          <textarea
            id="event-edit-description"
            placeholder="optional"
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            disabled={disabled}
          />
          <br />
          <label htmlFor="event-edit-day">Day</label>
          <br />
          <div
            style={
              disabled ? { pointerEvents: "none", opacity: 0.5 } : undefined
            }
          >
            <DayPickerInputWrapper
              id="event-edit-day"
              value={day}
              onDayChange={handleDayChange}
              inputDisabled={disabled}
              disabledDays={
                event.start_date
                  ? [
                      {
                        after: dayjs(event.start_date).add(6, "month").toDate(),
                      },
                    ]
                  : []
              }
            />
          </div>
          <br />
          <br />
          <label htmlFor="event-edit-start-time">Start Time</label>
          <select
            id="event-edit-start-time"
            value={startTime}
            onChange={(e) => setStartTime(e.target.value)}
            disabled={disabled || allDay}
          >
            <option />
            {generateTimes().map((time) => (
              <option key={time.value} value={time.value}>
                {time.display}
              </option>
            ))}
          </select>
          <br />
          <label htmlFor="event-edit-end-time">End Time</label>
          <select
            id="event-edit-end-time"
            value={endTime}
            onChange={(e) => setEndTime(e.target.value)}
            disabled={disabled || allDay}
          >
            <option />
            {generateTimes().map((time) => (
              <option key={time.value} value={time.value}>
                {time.display}
              </option>
            ))}
          </select>
          <br />
          <label htmlFor="event-edit-all-day">All Day</label>
          {"  "}
          <input
            id="event-edit-all-day"
            type="checkbox"
            checked={allDay}
            onChange={(e) => {
              if (e.target.checked) {
                setAllDay(true);
                setStartTime("");
                setEndTime("");
              } else {
                setAllDay(false);
              }
            }}
            disabled={disabled}
          />
          <br />
          <br />
          <button
            type="submit"
            className={
              loadingAction === "submit"
                ? "button-dark button-loader"
                : "button-dark"
            }
            disabled={disabled}
          >
            Update
          </button>
        </form>
      </fieldset>
      <ConfirmModal
        isOpen={confirmDeleteOpen}
        message="Do you really want to delete this event?"
        onConfirm={handleDeleteConfirm}
        onCancel={handleDeleteCancel}
      />
    </div>
  );
}

export default EventsEdit;
