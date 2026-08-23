import { useEffect, useState } from "react";
import { useParams } from "react-router";
import DayPickerInputWrapper from "../common/day_picker_input";
import dayjs from "dayjs";
import axios from "axios";
import { observer } from "mobx-react-lite";
import { useStore } from "../../helpers/store_context";
import handleAxiosError from "../../helpers/handle_axios_error";
import useDirtyReport from "../../helpers/use_dirty_report";
import useMountedRef from "../../helpers/use_mounted_ref";
import ModalFormHeader from "../modal_form/header";

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
  const mountedRef = useMountedRef();

  // Hosts cache: kick off fetch if empty; no-op if already loaded.
  useEffect(
    function () {
      store.ensureHosts();
    },
    [store],
  );

  function handleSubmit(e) {
    e.preventDefault();
    setLoading(true);
    axios
      .post(`/api/v1/guest-room-reservations`, {
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

  // Dirty means the user changed something; the empty defaults the
  // form opens with do not count (ADR 0006).
  useDirtyReport(setDirty, residentId !== "" || day !== null);

  const hosts = store.hosts;
  return (
    <div>
      <ModalFormHeader
        title="New Guest Room Reservation"
        onClose={handleCloseModal}
      />
      {/* `data-populated` reflects whether the data needed to fully use
          the form (the host list) is available. Present at first paint
          when the cache is warm; absent only while a cold fetch is in
          flight. Consumed by the modal perf benchmark as an
          apples-to-apples "user can see real data" signal. */}
      <fieldset data-populated={store.hostsLoaded ? "true" : undefined}>
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
              onDayChange={setDay}
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
