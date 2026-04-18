import { Component } from "react";
import axios from "axios";
import Cookie from "js-cookie";
import dayjs from "dayjs";
import utc from "dayjs/plugin/utc";
import timezone from "dayjs/plugin/timezone";
import DayPickerInputWrapper from "../common/day_picker_input";
import { generateTimes, toPacificDayjs } from "../../helpers/helpers";
import handleAxiosError from "../../helpers/handle_axios_error";
import { FontAwesomeIcon } from "@fortawesome/react-fontawesome";
import { faTimes } from "@fortawesome/free-solid-svg-icons";
import ConfirmModal from "../app/confirm_modal";

dayjs.extend(utc);
dayjs.extend(timezone);

// Render the full form from the first frame; the per-event fetch hydrates
// the inputs when it returns. There's no hosts dependency here (events
// don't belong to a resident) so `data-populated` simply tracks the event
// payload's arrival.
class EventsEdit extends Component {
  constructor(props) {
    super(props);
    this.handleDayChange = this.handleDayChange.bind(this);

    this.state = {
      loaded: false,
      event: {},
      title: "",
      description: "",
      day: "",
      start_time: "",
      end_time: "",
      all_day: false,
      loadingAction: null,
      confirmDeleteOpen: false,
    };
  }

  componentDidMount() {
    this._isMounted = true;
    var self = this;
    axios
      .get(`/api/v1/events/${self.props.eventId}?token=${Cookie.get("token")}`)
      .then(function (response) {
        if (!self._isMounted) return;
        if (response.status === 200) {
          var evt = response.data;
          var sd = toPacificDayjs(evt.start_date);
          self.setState({
            event: evt,
            loaded: true,
            title: evt.title,
            description: evt.description,
            day: new Date(sd.year(), sd.month(), sd.date()),
            start_time: `${toPacificDayjs(evt.start_date)
              .hour()
              .toString()
              .padStart(2, "0")}:${toPacificDayjs(evt.start_date)
              .minute()
              .toString()
              .padStart(2, "0")}`,
            end_time: evt.end_date
              ? `${toPacificDayjs(evt.end_date)
                  .hour()
                  .toString()
                  .padStart(2, "0")}:${toPacificDayjs(evt.end_date)
                  .minute()
                  .toString()
                  .padStart(2, "0")}`
              : "",
            all_day: evt.allday,
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
        `/api/v1/events/${self.props.eventId}/update?token=${Cookie.get(
          "token",
        )}`,
        {
          title: s.title,
          description: s.description,
          start_year: s.day && new Date(s.day).getFullYear(),
          start_month: s.day && new Date(s.day).getMonth() + 1,
          start_day: s.day && new Date(s.day).getDate(),
          start_hours: s.start_time && s.start_time.split(":")[0],
          start_minutes: s.start_time && s.start_time.split(":")[1],
          end_hours: s.end_time && s.end_time.split(":")[0],
          end_minutes: s.end_time && s.end_time.split(":")[1],
          all_day: s.all_day,
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
        `/api/v1/events/${self.props.eventId}/delete?token=${Cookie.get(
          "token",
        )}`,
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
    const disabled = this.state.loadingAction !== null || !this.state.loaded;
    return (
      <div>
        <div className="flex">
          <h2>Event</h2>
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
          />
        </div>
        <fieldset data-populated={this.state.loaded ? "true" : undefined}>
          <legend>Edit</legend>
          <form onSubmit={(e) => this.handleSubmit(e)}>
            <label>Title</label>
            <input
              type="text"
              value={this.state.title}
              onChange={(e) => this.setState({ title: e.target.value })}
              disabled={disabled}
            />
            <br />
            <label>Description</label>
            <textarea
              placeholder="optional"
              value={this.state.description}
              onChange={(e) => this.setState({ description: e.target.value })}
              disabled={disabled}
            />
            <br />
            <label>Day</label>
            <br />
            <div
              style={
                disabled ? { pointerEvents: "none", opacity: 0.5 } : undefined
              }
            >
              <DayPickerInputWrapper
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
            <label>Start Time</label>
            <select
              id="local.start_time"
              value={this.state.start_time}
              onChange={(e) => this.setState({ start_time: e.target.value })}
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
            <label>End Time</label>
            <select
              id="local.end_time"
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
            <label>All Day</label>
            {"  "}
            <input
              type="checkbox"
              id="local.all_day"
              checked={this.state.all_day}
              onChange={(e) => this.setState({ all_day: e.target.checked })}
              disabled={disabled}
            />
            <br />
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
          message="Do you really want to delete this event?"
          onConfirm={this.handleDeleteConfirm.bind(this)}
          onCancel={this.handleDeleteCancel.bind(this)}
        />
      </div>
    );
  }
}

export default EventsEdit;
