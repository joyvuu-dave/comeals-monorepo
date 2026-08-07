import { useEffect, useRef, useState } from "react";
import axios from "axios";
import dayjs from "dayjs";
import utc from "dayjs/plugin/utc";
import timezone from "dayjs/plugin/timezone";
import DayPickerInputWrapper from "../common/day_picker_input";
import { useStore } from "../../helpers/store_context";
import { toCommunityDayjs } from "../../helpers/helpers";
import handleAxiosError from "../../helpers/handle_axios_error";
import ConfirmModal from "../app/confirm_modal";
import useDirtyReport from "../../helpers/use_dirty_report";
import useMountedRef from "../../helpers/use_mounted_ref";
import ModalFormHeader from "../modal_form/header";
import ModalFormFooter from "../modal_form/footer";
import TimeSelect from "../modal_form/time_select";
import { buildStartEndPayload, toTimeString } from "../modal_form/payload";
import useDeleteFlow from "../modal_form/use_delete_flow";

dayjs.extend(utc);
dayjs.extend(timezone);

// Render the full form from the first frame; the per-event fetch hydrates
// the inputs when it returns. There's no hosts dependency here (events
// don't belong to a resident) so `data-populated` simply tracks the event
// payload's arrival.
function EventsEdit({ eventId, handleCloseModal, setDirty }) {
  const store = useStore();

  const [loaded, setLoaded] = useState(false);
  const [event, setEvent] = useState({});
  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [day, setDay] = useState(null);
  const [startTime, setStartTime] = useState("");
  const [endTime, setEndTime] = useState("");
  const [allDay, setAllDay] = useState(false);
  const [loadingAction, setLoadingAction] = useState(null);

  const mountedRef = useMountedRef();

  // The values the fetch hydrated, normalized for comparison. The form
  // fields are set FROM this object, so the dirty check below can
  // compare against it directly (ADR 0006).
  const initialRef = useRef(null);

  useEffect(
    function () {
      axios
        .get(`/api/v1/events/${eventId}`)
        .then(function (response) {
          if (!mountedRef.current) return;
          if (response.status === 200) {
            var evt = response.data;
            var sd = toCommunityDayjs(evt.start_date);
            var ed = evt.end_date ? toCommunityDayjs(evt.end_date) : null;
            // title and description are nullable in the database; a null
            // value would make the controlled inputs uncontrolled.
            var initial = {
              title: evt.title || "",
              description: evt.description || "",
              day: sd.format("YYYY-MM-DD"),
              startTime: toTimeString(sd),
              endTime: ed ? toTimeString(ed) : "",
              allDay: Boolean(evt.allday),
            };
            initialRef.current = initial;
            setEvent(evt);
            setLoaded(true);
            setTitle(initial.title);
            setDescription(initial.description);
            setDay(new Date(sd.year(), sd.month(), sd.date()));
            setStartTime(initial.startTime);
            setEndTime(initial.endTime);
            setAllDay(initial.allDay);
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
      .patch(`/api/v1/events/${eventId}/update`, {
        title: title,
        description: description,
        ...buildStartEndPayload(day, startTime, endTime),
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
    url: `/api/v1/events/${eventId}/delete`,
    message: "Do you really want to delete this event?",
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

  const disabled = loadingAction !== null || !loaded;

  const initial = initialRef.current;
  useDirtyReport(
    setDirty,
    initial !== null &&
      (title !== initial.title ||
        description !== initial.description ||
        (day ? dayjs(day).format("YYYY-MM-DD") : "") !== initial.day ||
        startTime !== initial.startTime ||
        endTime !== initial.endTime ||
        allDay !== initial.allDay),
  );

  return (
    <div>
      <ModalFormHeader title="Edit Event" onClose={handleCloseModal} />
      <fieldset data-populated={loaded ? "true" : undefined}>
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
              onDayChange={setDay}
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
          <TimeSelect
            id="event-edit-start-time"
            label="Start Time"
            value={startTime}
            onChange={setStartTime}
            disabled={disabled || allDay}
          />
          <br />
          <TimeSelect
            id="event-edit-end-time"
            label="End Time"
            value={endTime}
            onChange={setEndTime}
            disabled={disabled || allDay}
          />
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
}

export default EventsEdit;
