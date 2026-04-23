import { Component } from "react";
import DayPickerInputWrapper from "../common/day_picker_input";
import dayjs from "dayjs";
import utc from "dayjs/plugin/utc";
import timezone from "dayjs/plugin/timezone";
import axios from "axios";
import { generateTimes, toCommunityDayjs } from "../../helpers/helpers";
import handleAxiosError from "../../helpers/handle_axios_error";
import { inject, observer } from "mobx-react";
import { FontAwesomeIcon } from "@fortawesome/react-fontawesome";
import { faTimes } from "@fortawesome/free-solid-svg-icons";
import ConfirmModal from "../app/confirm_modal";

dayjs.extend(utc);
dayjs.extend(timezone);

// Render the full form from the first frame; the per-event fetch hydrates
// the inputs when it returns. The resident select is reactively bound to
// the shared `store.hosts` cache — see guest_room_reservations/edit.jsx
// for the full pattern.
const CommonHouseReservationsEdit = inject("store")(
  observer(
    class CommonHouseReservationsEdit extends Component {
      constructor(props) {
        super(props);
        this.handleDayChange = this.handleDayChange.bind(this);

        this.state = {
          loaded: false,
          event: {},
          resident_id: "",
          title: "",
          day: "",
          start_time: "",
          end_time: "",
          loadingAction: null,
          confirmDeleteOpen: false,
        };
      }

      componentDidMount() {
        this._isMounted = true;
        var self = this;
        // Hosts cache: kick off fetch if empty; no-op if already loaded.
        self.props.store.ensureHosts();

        axios
          .get(`/api/v1/common-house-reservations/${self.props.eventId}`)
          .then(function (response) {
            if (!self._isMounted) return;
            if (response.status === 200) {
              var evt = response.data.event;
              var sd = toCommunityDayjs(evt.start_date);
              self.setState({
                event: evt,
                loaded: true,
                resident_id: evt.resident_id,
                title: evt.title,
                day: new Date(sd.year(), sd.month(), sd.date()),
                start_time: `${toCommunityDayjs(evt.start_date)
                  .hour()
                  .toString()
                  .padStart(2, "0")}:${toCommunityDayjs(evt.start_date)
                  .minute()
                  .toString()
                  .padStart(2, "0")}`,
                end_time: `${toCommunityDayjs(evt.end_date)
                  .hour()
                  .toString()
                  .padStart(2, "0")}:${toCommunityDayjs(evt.end_date)
                  .minute()
                  .toString()
                  .padStart(2, "0")}`,
              });
            }
          })
          .catch(function (error) {
            handleAxiosError(error, { silent: true });
          });
      }

      componentWillUnmount() {
        this._isMounted = false;
      }

      handleSubmit(e) {
        e.preventDefault();
        this.setState({ loadingAction: "submit" });
        var self = this;
        var s = self.state;
        axios
          .patch(
            `/api/v1/common-house-reservations/${this.props.eventId}/update`,
            {
              resident_id: s.resident_id,
              start_year: s.day && new Date(s.day).getFullYear(),
              start_month: s.day && new Date(s.day).getMonth() + 1,
              start_day: s.day && new Date(s.day).getDate(),
              start_hours: s.start_time && s.start_time.split(":")[0],
              start_minutes: s.start_time && s.start_time.split(":")[1],
              end_hours: s.end_time && s.end_time.split(":")[0],
              end_minutes: s.end_time && s.end_time.split(":")[1],
              title: s.title,
            },
          )
          .then(function (response) {
            if (!self._isMounted) return;
            self.setState({ loadingAction: null });
            if (response.status === 200) {
              self.props.handleCloseModal();
            }
          })
          .catch(function (error) {
            if (!self._isMounted) return;
            self.setState({ loadingAction: null });
            handleAxiosError(error);
          });
      }

      handleDeleteClick() {
        if (this.state.loadingAction) return;
        this.setState({ confirmDeleteOpen: true });
      }

      handleDeleteConfirm() {
        this.setState({ confirmDeleteOpen: false, loadingAction: "delete" });
        var self = this;
        axios
          .delete(
            `/api/v1/common-house-reservations/${self.props.eventId}/delete`,
          )
          .then(function (response) {
            if (!self._isMounted) return;
            self.setState({ loadingAction: null });
            if (response.status === 200) {
              self.props.handleCloseModal();
            }
          })
          .catch(function (error) {
            if (!self._isMounted) return;
            self.setState({ loadingAction: null });
            handleAxiosError(error);
          });
      }

      handleDeleteCancel() {
        this.setState({ confirmDeleteOpen: false });
      }

      handleDayChange(val) {
        this.setState({ day: val });
      }

      render() {
        const residents = this.props.store.hosts;
        const disabled =
          this.state.loadingAction !== null || !this.state.loaded;
        const populated = this.state.loaded && this.props.store.hostsLoaded;
        return (
          <div>
            <div className="flex">
              <h2>Common House</h2>
              <button
                onClick={this.handleDeleteClick.bind(this)}
                type="button"
                className={
                  this.state.loadingAction === "delete"
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
                onClick={this.props.handleCloseModal}
                onKeyDown={(e) => {
                  if (e.key === "Enter" || e.key === " ") {
                    e.preventDefault();
                    this.props.handleCloseModal();
                  }
                }}
                role="button"
                aria-label="Close"
                tabIndex={0}
              />
            </div>
            <fieldset data-populated={populated ? "true" : undefined}>
              <legend>Edit</legend>
              <form onSubmit={(e) => this.handleSubmit(e)}>
                <label htmlFor="ch-edit-resident">Resident</label>
                <select
                  id="ch-edit-resident"
                  value={this.state.resident_id}
                  onChange={(e) =>
                    this.setState({ resident_id: e.target.value })
                  }
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
                  value={this.state.title}
                  onChange={(e) => this.setState({ title: e.target.value })}
                  disabled={disabled}
                />
                <br />
                <br />

                <label htmlFor="ch-edit-day">Day</label>
                <br />
                <div
                  style={
                    disabled
                      ? { pointerEvents: "none", opacity: 0.5 }
                      : undefined
                  }
                >
                  <DayPickerInputWrapper
                    id="ch-edit-day"
                    value={this.state.day}
                    onDayChange={this.handleDayChange}
                    inputDisabled={disabled}
                    disabledDays={
                      this.state.event.start_date
                        ? [
                            {
                              after: dayjs(this.state.event.start_date)
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
                  value={this.state.start_time}
                  onChange={(e) =>
                    this.setState({ start_time: e.target.value })
                  }
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
                  value={this.state.end_time}
                  onChange={(e) => this.setState({ end_time: e.target.value })}
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
                    this.state.loadingAction === "submit"
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
              isOpen={this.state.confirmDeleteOpen}
              message="Do you really want to delete this reservation?"
              onConfirm={this.handleDeleteConfirm.bind(this)}
              onCancel={this.handleDeleteCancel.bind(this)}
            />
          </div>
        );
      }
    },
  ),
);

export default CommonHouseReservationsEdit;
