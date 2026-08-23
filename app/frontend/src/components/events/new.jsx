import { useState } from "react";
import { useParams } from "react-router";
import DayPickerInputWrapper from "../common/day_picker_input";
import dayjs from "dayjs";
import axios from "axios";
import { useStore } from "../../helpers/store_context";
import handleAxiosError from "../../helpers/handle_axios_error";
import useDirtyReport from "../../helpers/use_dirty_report";
import useMountedRef from "../../helpers/use_mounted_ref";
import ModalFormHeader from "../modal_form/header";
import TimeSelect from "../modal_form/time_select";
import { buildStartEndPayload } from "../modal_form/payload";

function EventsNew({ handleCloseModal, setDirty }) {
  const store = useStore();
  const params = useParams();

  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [day, setDay] = useState(null);
  const [startTime, setStartTime] = useState("");
  const [endTime, setEndTime] = useState("");
  const [allDay, setAllDay] = useState(false);
  const [loading, setLoading] = useState(false);
  const mountedRef = useMountedRef();

  function handleSubmit(e) {
    e.preventDefault();
    setLoading(true);
    axios
      .post(`/api/v1/events`, {
        title: title,
        description: description,
        ...buildStartEndPayload(day, startTime, endTime),
        all_day: allDay,
      })
      .then(function (response) {
        if (!mountedRef.current) return;
        setLoading(false);
        if (response.status === 200) {
          // The client that knows, invalidates (issue #37): the new
          // event's month may be too far out to have a Pusher channel.
          store.invalidateMonthForDate(day);
          // The event is saved now; close without the discard
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
    title !== "" ||
      description !== "" ||
      day !== null ||
      startTime !== "" ||
      endTime !== "" ||
      allDay,
  );

  return (
    <div>
      <ModalFormHeader title="New Event" onClose={handleCloseModal} />
      <fieldset>
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
            id="event-new-start-time"
            label="Start Time"
            value={startTime}
            onChange={setStartTime}
            disabled={loading || allDay}
          />
          <br />
          <TimeSelect
            id="event-new-end-time"
            label="End Time"
            value={endTime}
            onChange={setEndTime}
            disabled={loading || allDay}
          />
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
