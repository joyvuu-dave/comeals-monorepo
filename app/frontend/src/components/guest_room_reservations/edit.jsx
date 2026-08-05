import { useEffect, useRef, useState } from "react";
import DayPickerInputWrapper from "../common/day_picker_input";
import dayjs from "dayjs";
import axios from "axios";
import { observer } from "mobx-react-lite";
import { useStore } from "../../helpers/store_context";
import handleAxiosError from "../../helpers/handle_axios_error";
import ConfirmModal from "../app/confirm_modal";
import useDirtyReport from "../../helpers/use_dirty_report";
import { FontAwesomeIcon } from "@fortawesome/react-fontawesome";
import { faTimes } from "@fortawesome/free-solid-svg-icons";

// Render the full form from the first frame; the per-event fetch hydrates
// the inputs when it returns. The host select is reactively bound to the
// shared `store.hosts` cache populated by ensureHosts() — so on repeat
// opens (cache warm) the dropdown is usable immediately, and only the
// per-record axios.get gates "data-populated".
//
// Submit is disabled until the event has loaded (`loaded`) so the user
// can't accidentally PATCH with placeholder/empty field values in the
// brief window before the fetch returns.
const GuestRoomReservationsEdit = observer(
  ({ eventId, handleCloseModal, setDirty }) => {
    const store = useStore();

    const [loaded, setLoaded] = useState(false);
    const [event, setEvent] = useState({});
    const [residentId, setResidentId] = useState("");
    const [day, setDay] = useState("");
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
          .get(`/api/v1/guest-room-reservations/${eventId}`)
          .then(function (response) {
            if (!mountedRef.current) return;
            if (response.status === 200) {
              var evt = response.data.event;
              initialRef.current = {
                residentId: String(evt.resident_id),
                day: dayjs(evt.date).format("YYYY-MM-DD"),
              };
              setEvent(evt);
              setLoaded(true);
              setResidentId(evt.resident_id);
              setDay(evt.date);
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
        .patch(`/api/v1/guest-room-reservations/${eventId}/update`, {
          resident_id: residentId,
          date: day ? dayjs(day).format("YYYY-MM-DD") : null,
        })
        .then(function (response) {
          if (!mountedRef.current) return;
          setLoadingAction(null);
          if (response.status === 200) {
            // The client that knows, invalidates (issue #37). Both
            // months: the edit may have moved the reservation out of
            // its old month.
            store.invalidateMonthForDate(event.date);
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
        .delete(`/api/v1/guest-room-reservations/${eventId}/delete`)
        .then(function (response) {
          if (!mountedRef.current) return;
          setLoadingAction(null);
          if (response.status === 200) {
            // The client that knows, invalidates (issue #37).
            store.invalidateMonthForDate(event.date);
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

    const hosts = store.hosts;
    const disabled = loadingAction !== null || !loaded;
    // `data-populated` flips true only when the per-event fetch has
    // landed — Edit modals depend on both the hosts cache AND the
    // record payload, so waiting on both gives an honest "user can
    // see the actual data" signal for the benchmark.
    const populated = loaded && store.hostsLoaded;

    const initial = initialRef.current;
    useDirtyReport(
      setDirty,
      initial !== null &&
        (String(residentId) !== initial.residentId ||
          (day ? dayjs(day).format("YYYY-MM-DD") : "") !== initial.day),
    );

    return (
      <div>
        <div className="flex">
          <h2>Guest Room Reservation</h2>
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
        <fieldset data-populated={populated ? "true" : undefined}>
          <legend>Edit</legend>
          <form onSubmit={handleSubmit}>
            <label htmlFor="guest-room-edit-host">Host</label>
            <select
              id="guest-room-edit-host"
              value={residentId}
              onChange={(e) => setResidentId(e.target.value)}
              disabled={disabled}
            >
              {/* Empty placeholder so the controlled value="" (pre-fetch
                or if the selected host disappears from a mid-edit
                Pusher refresh) always matches an option — silences
                React's "value does not match any option" warning. */}
              <option />
              {hosts.map((host) => (
                <option key={host.id} value={host.id}>
                  {host.unitName} - {host.name}
                </option>
              ))}
            </select>
            <br />

            <label htmlFor="guest-room-edit-day">Day</label>
            <br />
            <div
              style={
                disabled ? { pointerEvents: "none", opacity: 0.5 } : undefined
              }
            >
              <DayPickerInputWrapper
                id="guest-room-edit-day"
                value={day}
                onDayChange={handleDayChange}
                inputDisabled={disabled}
                disabledDays={
                  event.date
                    ? [
                        {
                          after: dayjs(event.date).add(6, "month").toDate(),
                        },
                      ]
                    : []
                }
              />
            </div>
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

export default GuestRoomReservationsEdit;
