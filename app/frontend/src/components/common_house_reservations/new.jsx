import { useEffect, useRef, useState } from "react";
import { useParams } from "react-router";
import DayPickerInputWrapper from "../common/day_picker_input";
import dayjs from "dayjs";
import axios from "axios";
import Cookie from "js-cookie";
import { observer } from "mobx-react-lite";
import { useStore } from "../../helpers/store_context";
import { generateTimes } from "../../helpers/helpers";
import handleAxiosError from "../../helpers/handle_axios_error";
import { FontAwesomeIcon } from "@fortawesome/react-fontawesome";
import { faTimes } from "@fortawesome/free-solid-svg-icons";

// No `ready` gate: render the full form from the first frame. The resident
// select is reactively bound to `store.hosts` (populated on mount via
// store.ensureHosts()), so the dropdown lights up as soon as the cached
// or freshly-fetched list is available — and stays in sync in real time
// via the Pusher `community-<id>-residents` subscription.
const CommonHouseReservationsNew = observer(({ handleCloseModal }) => {
  const store = useStore();
  const params = useParams();

  const [residentId, setResidentId] = useState("");
  const [title, setTitle] = useState("");
  const [day, setDay] = useState(null);
  const [startTime, setStartTime] = useState("");
  const [endTime, setEndTime] = useState("");
  const [loading, setLoading] = useState(false);

  const communityId = useRef(Cookie.get("community_id")).current;

  // The POST outlives a closed modal; the flag keeps its callbacks
  // from setting state after unmount, like the class's _isMounted.
  const mountedRef = useRef(true);
  useEffect(
    function () {
      mountedRef.current = true;
      // Hosts cache: kick off fetch if empty; no-op if already loaded.
      store.ensureHosts();
      return function () {
        mountedRef.current = false;
      };
    },
    [store],
  );

  function handleSubmit(e) {
    e.preventDefault();
    setLoading(true);
    axios
      .post(`/api/v1/common-house-reservations?community_id=${communityId}`, {
        resident_id: residentId,
        start_year: day && day.getFullYear(),
        start_month: day && day.getMonth() + 1,
        start_day: day && day.getDate(),
        start_hours: startTime && startTime.split(":")[0],
        start_minutes: startTime && startTime.split(":")[1],
        end_hours: endTime && endTime.split(":")[0],
        end_minutes: endTime && endTime.split(":")[1],
        title: title,
      })
      .then(function (response) {
        if (!mountedRef.current) return;
        setLoading(false);
        if (response.status === 200) {
          // The client that knows, invalidates (issue #37): the new
          // reservation's month may be too far out to have a Pusher
          // channel.
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

  const residents = store.hosts;
  return (
    <div>
      <div className="flex">
        <h2>Common House</h2>
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
      {/* `data-populated` reflects whether the data needed to fully use
          the form (the residents list) is available. Present at first
          paint when the cache is warm; absent only while a cold fetch
          is in flight. See sibling comment in guest_room_reservations/new.jsx. */}
      <fieldset data-populated={store.hostsLoaded ? "true" : undefined}>
        <legend>New</legend>
        <form onSubmit={handleSubmit}>
          <label htmlFor="ch-new-resident">Resident</label>
          <select
            id="ch-new-resident"
            value={residentId}
            disabled={loading}
            onChange={(e) => setResidentId(e.target.value)}
          >
            <option />
            {residents.map((resident) => (
              <option key={resident.id} value={resident.id}>
                {resident.unitName} - {resident.name}
              </option>
            ))}
          </select>
          <br />
          <label htmlFor="ch-new-title">Title</label>
          <br />
          <input
            type="text"
            id="ch-new-title"
            placeholder="optional"
            disabled={loading}
            value={title}
            onChange={(e) => setTitle(e.target.value)}
          />
          <br />

          <label htmlFor="ch-new-day">Day</label>
          <br />
          <div
            style={
              loading ? { pointerEvents: "none", opacity: 0.5 } : undefined
            }
          >
            <DayPickerInputWrapper
              id="ch-new-day"
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

          <label htmlFor="ch-new-start-time">Start Time</label>
          <select
            id="ch-new-start-time"
            value={startTime}
            disabled={loading}
            onChange={(e) => setStartTime(e.target.value)}
          >
            <option />
            {generateTimes().map((time) => (
              <option key={time.value} value={time.value}>
                {time.display}
              </option>
            ))}
          </select>
          <br />

          <label htmlFor="ch-new-end-time">End Time</label>
          <select
            id="ch-new-end-time"
            value={endTime}
            disabled={loading}
            onChange={(e) => setEndTime(e.target.value)}
          >
            <option />
            {generateTimes().map((time) => (
              <option key={time.value} value={time.value}>
                {time.display}
              </option>
            ))}
          </select>
          <br />

          <button
            type="submit"
            className={loading ? "button-dark button-loader" : "button-dark"}
            disabled={loading || !store.hostsLoaded}
          >
            Create
          </button>
        </form>
      </fieldset>
    </div>
  );
});

export default CommonHouseReservationsNew;
