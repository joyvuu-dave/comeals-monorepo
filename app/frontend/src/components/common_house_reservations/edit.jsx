import { useEffect, useRef, useState } from "react";
import DayPickerInputWrapper from "../common/day_picker_input";
import dayjs from "dayjs";
import utc from "dayjs/plugin/utc";
import timezone from "dayjs/plugin/timezone";
import axios from "axios";
import { generateTimes, toCommunityDayjs } from "../../helpers/helpers";
import handleAxiosError from "../../helpers/handle_axios_error";
import { observer } from "mobx-react-lite";
import { useStore } from "../../helpers/store_context";
import Icon from "../icon";
import ConfirmModal from "../app/confirm_modal";
import useDirtyReport from "../../helpers/use_dirty_report";

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
    const [day, setDay] = useState("");
    const [startTime, setStartTime] = useState("");
    const [endTime, setEndTime] = useState("");
    const [loadingAction, setLoadingAction] = useState(null);
    const [confirmDeleteOpen, setConfirmDeleteOpen] = useState(false);

    // The requests outlive a closed modal; the flag keeps their
    // callbacks from setting state after unmount, like the class's
    // _isMounted.
    const mountedRef = useRef(true);

    // The values the fetch hydrated, normalized for comparison. The
    // form is dirty when any field differs from these (ADR 0006).
    const initialRef = useRef(null);

    useEffect(
      function () {
        mountedRef.current = true;
        // Hosts cache: kick off fetch if empty; no-op if already loaded.
        store.ensureHosts();

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
                startTime: `${sd.hour().toString().padStart(2, "0")}:${sd
                  .minute()
                  .toString()
                  .padStart(2, "0")}`,
                endTime: `${ed.hour().toString().padStart(2, "0")}:${ed
                  .minute()
                  .toString()
                  .padStart(2, "0")}`,
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

        return function () {
          mountedRef.current = false;
        };
      },
      [eventId, store],
    );

    function handleSubmit(e) {
      e.preventDefault();
      setLoadingAction("submit");
      axios
        .patch(`/api/v1/common-house-reservations/${eventId}/update`, {
          resident_id: residentId,
          start_year: day && new Date(day).getFullYear(),
          start_month: day && new Date(day).getMonth() + 1,
          start_day: day && new Date(day).getDate(),
          start_hours: startTime && startTime.split(":")[0],
          start_minutes: startTime && startTime.split(":")[1],
          end_hours: endTime && endTime.split(":")[0],
          end_minutes: endTime && endTime.split(":")[1],
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

    function handleDeleteClick() {
      if (loadingAction) return;
      setConfirmDeleteOpen(true);
    }

    function handleDeleteConfirm() {
      setConfirmDeleteOpen(false);
      setLoadingAction("delete");
      axios
        .delete(`/api/v1/common-house-reservations/${eventId}/delete`)
        .then(function (response) {
          if (!mountedRef.current) return;
          setLoadingAction(null);
          if (response.status === 200) {
            // The client that knows, invalidates (issue #37).
            store.invalidateMonthForDate(event.start_date);
            // The record is gone; edited fields have nothing left to
            // protect (ADR 0006).
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

    function handleDeleteCancel() {
      setConfirmDeleteOpen(false);
    }

    function handleDayChange(val) {
      setDay(val);
    }

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
        <div className="flex">
          <h2>Common House</h2>
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
                onDayChange={handleDayChange}
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

            <label htmlFor="ch-edit-start-time">Start Time</label>
            <select
              id="ch-edit-start-time"
              value={startTime}
              onChange={(e) => setStartTime(e.target.value)}
              disabled={disabled}
            >
              <option />
              {generateTimes().map((time) => (
                <option key={time.value} value={time.value}>
                  {time.display}
                </option>
              ))}
            </select>
            <br />

            <label htmlFor="ch-edit-end-time">End Time</label>
            <select
              id="ch-edit-end-time"
              value={endTime}
              onChange={(e) => setEndTime(e.target.value)}
              disabled={disabled}
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
          message="Do you really want to delete this reservation?"
          cancelLabel="Cancel"
          confirmLabel="Delete"
          armMs={400}
          onConfirm={handleDeleteConfirm}
          onCancel={handleDeleteCancel}
        />
      </div>
    );
  },
);

export default CommonHouseReservationsEdit;
