import { useEffect, useRef, useState } from "react";
import { useParams } from "react-router";
import DayPickerInputWrapper from "../common/day_picker_input";
import dayjs from "dayjs";
import axios from "axios";
import Cookie from "js-cookie";
import { useStore } from "../../helpers/store_context";
import { generateTimes } from "../../helpers/helpers";
import handleAxiosError from "../../helpers/handle_axios_error";
import { FontAwesomeIcon } from "@fortawesome/react-fontawesome";
import { faTimes } from "@fortawesome/free-solid-svg-icons";

function EventsNew({ handleCloseModal }) {
  const store = useStore();
  const params = useParams();

  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [day, setDay] = useState(null);
  const [startTime, setStartTime] = useState("");
  const [endTime, setEndTime] = useState("");
  const [allDay, setAllDay] = useState(false);
  const [loading, setLoading] = useState(false);

  const communityId = useRef(Cookie.get("community_id")).current;

  // The POST outlives a closed modal; the flag keeps its callbacks
  // from setting state after unmount, like the class's _isMounted.
  const mountedRef = useRef(true);
  useEffect(function () {
    mountedRef.current = true;
    return function () {
      mountedRef.current = false;
    };
  }, []);

  function handleSubmit(e) {
    e.preventDefault();
    setLoading(true);
    axios
      .post(`/api/v1/events?community_id=${communityId}`, {
        title: title,
        description: description,
        start_year: day && day.getFullYear(),
        start_month: day && day.getMonth() + 1,
        start_day: day && day.getDate(),
        start_hours: startTime && startTime.split(":")[0],
        start_minutes: startTime && startTime.split(":")[1],
        end_hours: endTime && endTime.split(":")[0],
        end_minutes: endTime && endTime.split(":")[1],
        all_day: allDay,
      })
      .then(function (response) {
        if (!mountedRef.current) return;
        setLoading(false);
        if (response.status === 200) {
          // The client that knows, invalidates (issue #37): the new
          // event's month may be too far out to have a Pusher channel.
          store.invalidateMonthForDate(day);
          handleCloseModal();
        }
      })
      .catch(function (error) {
        if (!mountedRef.current) return;
        setLoading(false);
        handleAxiosError(error);
      });
  }

  function handleDayChange(val) {
    setDay(val);
  }

  return (
    <div>
      <div className="flex">
        <h2>Event</h2>
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
      <fieldset>
        <legend>New</legend>
        <form onSubmit={handleSubmit}>
          <label htmlFor="event-new-title">Title</label>
          <input
            type="text"
            id="event-new-title"
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            disabled={loading}
          />
          <br />
          <label htmlFor="event-new-description">Description</label>
          <textarea
            id="event-new-description"
            placeholder="optional"
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            disabled={loading}
          />
          <br />
          <label htmlFor="event-new-day">Day</label>
          <br />
          <div
            style={
              loading ? { pointerEvents: "none", opacity: 0.5 } : undefined
            }
          >
            <DayPickerInputWrapper
              id="event-new-day"
              value={day}
              placeholder=""
              onDayChange={handleDayChange}
              inputDisabled={loading}
              defaultMonth={dayjs(params.date).toDate()}
              disabledDays={[
                {
                  after: dayjs(params.date).add(6, "month").toDate(),
                },
              ]}
            />
          </div>
          <br />
          <br />
          <label htmlFor="event-new-start-time">Start Time</label>
          <select
            id="event-new-start-time"
            value={startTime}
            onChange={(e) => setStartTime(e.target.value)}
            disabled={loading || allDay}
          >
            <option />
            {generateTimes().map((time) => (
              <option key={time.value} value={time.value}>
                {time.display}
              </option>
            ))}
          </select>
          <br />
          <label htmlFor="event-new-end-time">End Time</label>
          <select
            id="event-new-end-time"
            value={endTime}
            onChange={(e) => setEndTime(e.target.value)}
            disabled={loading || allDay}
          >
            <option />
            {generateTimes().map((time) => (
              <option key={time.value} value={time.value}>
                {time.display}
              </option>
            ))}
          </select>
          <br />
          <label htmlFor="event-new-all-day">All Day</label>
          {"  "}
          <input
            id="event-new-all-day"
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
            disabled={loading}
          />
          <br />
          <br />
          <button
            type="submit"
            className={loading ? "button-dark button-loader" : "button-dark"}
            disabled={loading}
          >
            Create
          </button>
        </form>
      </fieldset>
    </div>
  );
}

export default EventsNew;
