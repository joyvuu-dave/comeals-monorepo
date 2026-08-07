import { useEffect, useRef, useState } from "react";
import DayPickerInputWrapper from "../common/day_picker_input";
import dayjs from "dayjs";
import axios from "axios";
import { observer } from "mobx-react-lite";
import { useStore } from "../../helpers/store_context";
import handleAxiosError from "../../helpers/handle_axios_error";
import ConfirmModal from "../app/confirm_modal";
import useDirtyReport from "../../helpers/use_dirty_report";
import useMountedRef from "../../helpers/use_mounted_ref";
import ModalFormHeader from "../modal_form/header";
import ModalFormFooter from "../modal_form/footer";
import useDeleteFlow from "../modal_form/use_delete_flow";

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
    const [day, setDay] = useState(null);
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
          .get(`/api/v1/guest-room-reservations/${eventId}`)
          .then(function (response) {
            if (!mountedRef.current) return;
            if (response.status === 200) {
              var evt = response.data.event;
              var d = dayjs(evt.date);
              initialRef.current = {
                residentId: String(evt.resident_id),
                day: d.format("YYYY-MM-DD"),
              };
              setEvent(evt);
              setLoaded(true);
              setResidentId(evt.resident_id);
              setDay(new Date(d.year(), d.month(), d.date()));
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

    const deleteFlow = useDeleteFlow({
      url: `/api/v1/guest-room-reservations/${eventId}/delete`,
      message: "Do you really want to delete this reservation?",
      loadingAction: loadingAction,
      setLoadingAction: setLoadingAction,
      mountedRef: mountedRef,
      onDeleted: function () {
        // The client that knows, invalidates (issue #37).
        store.invalidateMonthForDate(event.date);
        // The record is gone; edited fields have nothing left to
        // protect (ADR 0006).
        setDirty(false);
        handleCloseModal();
      },
    });

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
        <ModalFormHeader
          title="Edit Guest Room Reservation"
          onClose={handleCloseModal}
        />
        <fieldset data-populated={populated ? "true" : undefined}>
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
                onDayChange={setDay}
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

            <ModalFormFooter
              submitting={loadingAction === "submit"}
              deleting={loadingAction === "delete"}
              onDelete={deleteFlow.requestDelete}
              disabled={disabled}
            />
          </form>
        </fieldset>
        <ConfirmModal {...deleteFlow.confirmProps} />
      </div>
    );
  },
);

export default GuestRoomReservationsEdit;
