import { useEffect, useRef, useState } from "react";
import { useParams } from "react-router";
import DayPickerInputWrapper from "../common/day_picker_input";
import dayjs from "dayjs";
import axios from "axios";
import Cookie from "js-cookie";
import { observer } from "mobx-react-lite";
import { useStore } from "../../helpers/store_context";
import handleAxiosError from "../../helpers/handle_axios_error";
import Icon from "../icon";
import useDirtyReport from "../../helpers/use_dirty_report";

// No `ready` gate: render the full form from the first frame. The host
// select is reactively bound to `store.hosts` (populated on mount via
// store.ensureHosts()), so the dropdown lights up as soon as the cached
// or freshly-fetched list is available — and stays in sync in real time
// via the Pusher `community-<id>-residents` subscription.
const GuestRoomReservationsNew = observer(({ handleCloseModal, setDirty }) => {
  const store = useStore();
  const params = useParams();

  const [residentId, setResidentId] = useState("");
  const [day, setDay] = useState(null);
  const [loading, setLoading] = useState(false);

  const communityId = useRef(Cookie.get("community_id")).current;

  // The POST outlives a closed modal; the flag keeps its callbacks
  // from setting state after unmount, like the class's _isMounted.
  const mountedRef = useRef(true);
  useEffect(
    function () {
      mountedRef.current = true;
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
      .post(`/api/v1/guest-room-reservations?community_id=${communityId}`, {
        resident_id: residentId,
        date: day ? dayjs(day).format("YYYY-MM-DD") : null,
      })
      .then(function (response) {
        if (!mountedRef.current) return;
        setLoading(false);
        if (response.status === 200) {
          // The client that knows, invalidates (issue #37): the new
          // reservation's month may be too far out to have a Pusher
          // channel.
          store.invalidateMonthForDate(day);
          // The reservation is saved now; close without the discard
          // question (ADR 0006).
          setDirty(false);
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

  // Dirty means the user changed something; the empty defaults the
  // form opens with do not count (ADR 0006).
  useDirtyReport(setDirty, residentId !== "" || day !== null);

  const hosts = store.hosts;
  return (
    <div>
      <div className="flex">
        <h2>Guest Room Reservation</h2>
        <Icon
          name="xmark"
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
          the form (the host list) is available. Present at first paint
          when the cache is warm; absent only while a cold fetch is in
          flight. Consumed by the modal perf benchmark as an
          apples-to-apples "user can see real data" signal. */}
      <fieldset data-populated={store.hostsLoaded ? "true" : undefined}>
        <legend>New</legend>
        <form onSubmit={handleSubmit}>
          <label htmlFor="guest-room-new-host">Host</label>
          <select
            id="guest-room-new-host"
            value={residentId}
            onChange={(e) => setResidentId(e.target.value)}
            disabled={loading}
          >
            <option />
            {hosts.map((host) => (
              <option key={host.id} value={host.id}>
                {host.unitName} - {host.name}
              </option>
            ))}
          </select>
          <br />

          <label htmlFor="guest-room-new-day">Day</label>
          <br />
          <div
            style={
              loading ? { pointerEvents: "none", opacity: 0.5 } : undefined
            }
          >
            <DayPickerInputWrapper
              id="guest-room-new-day"
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

export default GuestRoomReservationsNew;
