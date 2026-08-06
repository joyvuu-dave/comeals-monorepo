import { useEffect, useRef, useState } from "react";
import DayPickerInputWrapper from "../common/day_picker_input";
import dayjs from "dayjs";
import utc from "dayjs/plugin/utc";
import timezone from "dayjs/plugin/timezone";
import axios from "axios";
import { toCommunityDayjs } from "../../helpers/helpers";
import handleAxiosError from "../../helpers/handle_axios_error";
import { observer } from "mobx-react-lite";
import { useStore } from "../../helpers/store_context";
import ConfirmModal from "../app/confirm_modal";
import useDirtyReport from "../../helpers/use_dirty_report";
import useMountedRef from "../../helpers/use_mounted_ref";
import ModalFormHeader from "../modal_form/header";
import TimeSelect from "../modal_form/time_select";
import { buildStartEndPayload, toTimeString } from "../modal_form/payload";
import useDeleteFlow from "../modal_form/use_delete_flow";

dayjs.extend(utc);
dayjs.extend(timezone);

// Render the full form from the first frame; the per-event fetch hydrates
// the inputs when it returns. The resident select is reactively bound to
// the shared `store.hosts` cache — see guest_room_reservations/edit.jsx
// for the full pattern.
const CommonHouseReservationsEdit = observer(
  ({ eventId, handleCloseModal, setDirty }) => {
    const store = useStore();

    const [loaded, setLoaded] = useState(false);
    const [event, setEvent] = useState({});
    const [residentId, setResidentId] = useState("");
    const [title, setTitle] = useState("");
    const [day, setDay] = useState(null);
    const [startTime, setStartTime] = useState("");
    const [endTime, setEndTime] = useState("");
    const [loadingAction, setLoadingAction] = useState(null);

    const mountedRef = useMountedRef();

    // The values the fetch hydrated, normalized for comparison. The form
    // fields are set FROM this object, so the dirty check below can
    // compare against it directly (ADR 0006).
    const initialRef = useRef(null);

    // Hosts cache: kick off fetch if empty; no-op if already loaded.
    useEffect(
      function () {
        store.ensureHosts();
      },
      [store],
    );

    useEffect(
      function () {
        axios
          .get(`/api/v1/common-house-reservations/${eventId}`)
          .then(function (response) {
            if (!mountedRef.current) return;
            if (response.status === 200) {
              var evt = response.data.event;
              var sd = toCommunityDayjs(evt.start_date);
              var ed = toCommunityDayjs(evt.end_date);
              // title is nullable in the database; a null value would make
              // the controlled input uncontrolled.
              var initial = {
                residentId: String(evt.resident_id),
                title: evt.title || "",
                day: sd.format("YYYY-MM-DD"),
                startTime: toTimeString(sd),
                endTime: toTimeString(ed),
              };
              initialRef.current = initial;
              setEvent(evt);
              setLoaded(true);
              setResidentId(evt.resident_id);
              setTitle(initial.title);
              setDay(new Date(sd.year(), sd.month(), sd.date()));
              setStartTime(initial.startTime);
              setEndTime(initial.endTime);
            }
          })
          .catch(function (error) {
            handleAxiosError(error, { silent: true });
          });
      },
      [eventId, mountedRef],
    );

    function handleSubmit(e) {
      e.preventDefault();
      setLoadingAction("submit");
      axios
        .patch(`/api/v1/common-house-reservations/${eventId}/update`, {
          resident_id: residentId,
          ...buildStartEndPayload(day, startTime, endTime),
          title: title,
        })
        .then(function (response) {
          if (!mountedRef.current) return;
          setLoadingAction(null);
          if (response.status === 200) {
            // The client that knows, invalidates (issue #37). Both
            // months: the edit may have moved the reservation out of
            // its old month.
            store.invalidateMonthForDate(event.start_date);
            store.invalidateMonthForDate(day);
            // The changes are saved now; close without the discard
            // question (ADR 0006).
            setDirty(false);
            handleCloseModal();
          }
        })
        .catch(function (error) {
          if (!mountedRef.current) return;
          setLoadingAction(null);
          handleAxiosError(error);
        });
    }

    const deleteFlow = useDeleteFlow({
      url: `/api/v1/common-house-reservations/${eventId}/delete`,
      message: "Do you really want to delete this reservation?",
      loadingAction: loadingAction,
      setLoadingAction: setLoadingAction,
      mountedRef: mountedRef,
      onDeleted: function () {
        // The client that knows, invalidates (issue #37).
        store.invalidateMonthForDate(event.start_date);
        // The record is gone; edited fields have nothing left to
        // protect (ADR 0006).
        setDirty(false);
        handleCloseModal();
      },
    });

    const residents = store.hosts;
    const disabled = loadingAction !== null || !loaded;
    const populated = loaded && store.hostsLoaded;

    const initial = initialRef.current;
    useDirtyReport(
      setDirty,
      initial !== null &&
        (String(residentId) !== initial.residentId ||
          title !== initial.title ||
          (day ? dayjs(day).format("YYYY-MM-DD") : "") !== initial.day ||
          startTime !== initial.startTime ||
          endTime !== initial.endTime),
    );
    return (
      <div>
        <ModalFormHeader
          title="Common House"
          onClose={handleCloseModal}
          onDelete={deleteFlow.requestDelete}
          deleting={loadingAction === "delete"}
          disabled={disabled}
        />
        <fieldset data-populated={populated ? "true" : undefined}>
          <legend>Edit</legend>
          <form onSubmit={handleSubmit}>
            <label htmlFor="ch-edit-resident">Resident</label>
            <select
              id="ch-edit-resident"
              value={residentId}
              onChange={(e) => setResidentId(e.target.value)}
              disabled={disabled}
            >
              {/* Empty placeholder so the controlled value="" (pre-fetch
                  or if the selected resident disappears from a mid-edit
                  Pusher refresh) always matches an option — silences
                  React's "value does not match any option" warning. */}
              <option />
              {residents.map((resident) => (
                <option key={resident.id} value={resident.id}>
                  {resident.unitName} - {resident.name}
                </option>
              ))}
            </select>
            <br />

            <label htmlFor="ch-edit-title">Title</label>
            <br />
            <input
              type="text"
              id="ch-edit-title"
              placeholder="optional"
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              disabled={disabled}
            />
            <br />
            <br />

            <label htmlFor="ch-edit-day">Day</label>
            <br />
            <div
              style={
                disabled ? { pointerEvents: "none", opacity: 0.5 } : undefined
              }
            >
              <DayPickerInputWrapper
                id="ch-edit-day"
                value={day}
                onDayChange={setDay}
                inputDisabled={disabled}
                disabledDays={
                  event.start_date
                    ? [
                        {
                          after: dayjs(event.start_date)
                            .add(6, "month")
                            .toDate(),
                        },
                      ]
                    : []
                }
              />
            </div>
            <br />
            <br />

            <TimeSelect
              id="ch-edit-start-time"
              label="Start Time"
              value={startTime}
              onChange={setStartTime}
              disabled={disabled}
            />
            <br />

            <TimeSelect
              id="ch-edit-end-time"
              label="End Time"
              value={endTime}
              onChange={setEndTime}
              disabled={disabled}
            />
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
        <ConfirmModal {...deleteFlow.confirmProps} />
      </div>
    );
  },
);

export default CommonHouseReservationsEdit;
