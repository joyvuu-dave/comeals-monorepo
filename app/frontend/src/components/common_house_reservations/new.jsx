import { useEffect, useState } from "react";
import { useParams } from "react-router";
import DayPickerInputWrapper from "../common/day_picker_input";
import dayjs from "dayjs";
import axios from "axios";
import Cookie from "js-cookie";
import { observer } from "mobx-react-lite";
import { useStore } from "../../helpers/store_context";
import handleAxiosError from "../../helpers/handle_axios_error";
import useDirtyReport from "../../helpers/use_dirty_report";
import useMountedRef from "../../helpers/use_mounted_ref";
import ModalFormHeader from "../modal_form/header";
import TimeSelect from "../modal_form/time_select";
import { buildStartEndPayload } from "../modal_form/payload";

// No `ready` gate: render the full form from the first frame. The resident
// select is reactively bound to `store.hosts` (populated on mount via
// store.ensureHosts()), so the dropdown lights up as soon as the cached
// or freshly-fetched list is available — and stays in sync in real time
// via the Pusher `community-<id>-residents` subscription.
const CommonHouseReservationsNew = observer(
  ({ handleCloseModal, setDirty }) => {
    const store = useStore();
    const params = useParams();

    const [residentId, setResidentId] = useState("");
    const [title, setTitle] = useState("");
    const [day, setDay] = useState(null);
    const [startTime, setStartTime] = useState("");
    const [endTime, setEndTime] = useState("");
    const [loading, setLoading] = useState(false);

    const communityId = Cookie.get("community_id");
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
        .post(`/api/v1/common-house-reservations?community_id=${communityId}`, {
          resident_id: residentId,
          ...buildStartEndPayload(day, startTime, endTime),
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
    useDirtyReport(
      setDirty,
      residentId !== "" ||
        title !== "" ||
        day !== null ||
        startTime !== "" ||
        endTime !== "",
    );

    const residents = store.hosts;
    return (
      <div>
        <ModalFormHeader
          title="New Common House Reservation"
          onClose={handleCloseModal}
        />
        {/* `data-populated` reflects whether the data needed to fully use
          the form (the residents list) is available. Present at first
          paint when the cache is warm; absent only while a cold fetch
          is in flight. See sibling comment in guest_room_reservations/new.jsx. */}
        <fieldset data-populated={store.hostsLoaded ? "true" : undefined}>
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

            <TimeSelect
              id="ch-new-start-time"
              label="Start Time"
              value={startTime}
              onChange={setStartTime}
              disabled={loading}
            />
            <br />

            <TimeSelect
              id="ch-new-end-time"
              label="End Time"
              value={endTime}
              onChange={setEndTime}
              disabled={loading}
            />
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
  },
);

export default CommonHouseReservationsNew;
