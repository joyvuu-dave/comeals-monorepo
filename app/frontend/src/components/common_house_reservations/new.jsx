import { Component } from "react";
import DayPickerInputWrapper from "../common/day_picker_input";
import dayjs from "dayjs";
import axios from "axios";
import Cookie from "js-cookie";
import { inject, observer } from "mobx-react";
import { generateTimes } from "../../helpers/helpers";
import handleAxiosError from "../../helpers/handle_axios_error";
import { FontAwesomeIcon } from "@fortawesome/react-fontawesome";
import { faTimes } from "@fortawesome/free-solid-svg-icons";

// No `ready` gate: render the full form from the first frame. The resident
// select is reactively bound to `store.hosts` (populated on mount via
// store.ensureHosts()), so the dropdown lights up as soon as the cached
// or freshly-fetched list is available — and stays in sync in real time
// via the Pusher `community-<id>-residents` subscription.
const CommonHouseReservationsNew = inject("store")(
  observer(
    class CommonHouseReservationsNew extends Component {
      constructor(props) {
        super(props);
        this.handleDayChange = this.handleDayChange.bind(this);

        this.state = {
          communityId: Cookie.get("community_id"),
          resident_id: "",
          title: "",
          day: null,
          start_time: "",
          end_time: "",
          loading: false,
        };
      }

      componentDidMount() {
        this._isMounted = true;
        this.props.store.ensureHosts();
      }

      componentWillUnmount() {
        this._isMounted = false;
      }

      handleSubmit(e) {
        e.preventDefault();
        this.setState({ loading: true });
        var self = this;
        var s = self.state;
        axios
          .post(
            `/api/v1/common-house-reservations?community_id=${s.communityId}`,
            {
              resident_id: s.resident_id,
              start_year: s.day && s.day.getFullYear(),
              start_month: s.day && s.day.getMonth() + 1,
              start_day: s.day && s.day.getDate(),
              start_hours: s.start_time && s.start_time.split(":")[0],
              start_minutes: s.start_time && s.start_time.split(":")[1],
              end_hours: s.end_time && s.end_time.split(":")[0],
              end_minutes: s.end_time && s.end_time.split(":")[1],
              title: s.title,
            },
          )
          .then(function (response) {
            if (!self._isMounted) return;
            self.setState({ loading: false });
            if (response.status === 200) {
              self.props.handleCloseModal();
            }
          })
          .catch(function (error) {
            if (!self._isMounted) return;
            self.setState({ loading: false });
            handleAxiosError(error);
          });
      }

      handleDayChange(val) {
        this.setState({ day: val });
      }

      render() {
        const store = this.props.store;
        const residents = store.hosts;
        return (
          <div>
            <div className="flex">
              <h2>Common House</h2>
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
            {/* `data-populated` reflects whether the data needed to fully use
                the form (the residents list) is available. Present at first
                paint when the cache is warm; absent only while a cold fetch
                is in flight. See sibling comment in guest_room_reservations/new.jsx. */}
            <fieldset data-populated={store.hostsLoaded ? "true" : undefined}>
              <legend>New</legend>
              <form onSubmit={(e) => this.handleSubmit(e)}>
                <label htmlFor="ch-new-resident">Resident</label>
                <select
                  id="ch-new-resident"
                  value={this.state.resident_id}
                  disabled={this.state.loading}
                  onChange={(e) =>
                    this.setState({ resident_id: e.target.value })
                  }
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
                  disabled={this.state.loading}
                  value={this.state.title}
                  onChange={(e) => this.setState({ title: e.target.value })}
                />
                <br />

                <label htmlFor="ch-new-day">Day</label>
                <br />
                <div
                  style={
                    this.state.loading
                      ? { pointerEvents: "none", opacity: 0.5 }
                      : undefined
                  }
                >
                  <DayPickerInputWrapper
                    id="ch-new-day"
                    value={this.state.day}
                    placeholder=""
                    onDayChange={this.handleDayChange}
                    inputDisabled={this.state.loading}
                    defaultMonth={dayjs(this.props.match.params.date).toDate()}
                    disabledDays={[
                      {
                        after: dayjs(this.props.match.params.date)
                          .add(6, "month")
                          .toDate(),
                      },
                    ]}
                  />
                </div>
                <br />
                <br />

                <label htmlFor="ch-new-start-time">Start Time</label>
                <select
                  id="ch-new-start-time"
                  value={this.state.start_time}
                  disabled={this.state.loading}
                  onChange={(e) =>
                    this.setState({ start_time: e.target.value })
                  }
                >
                  <option />
                  {generateTimes().map((time) => (
                    <option key={time.value} value={time.value}>
                      {time.display}
                    </option>
                  ))}
                </select>
                <br />

                <label htmlFor="ch-new-end-time">End Time</label>
                <select
                  id="ch-new-end-time"
                  value={this.state.end_time}
                  disabled={this.state.loading}
                  onChange={(e) => this.setState({ end_time: e.target.value })}
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
                    this.state.loading
                      ? "button-dark button-loader"
                      : "button-dark"
                  }
                  disabled={this.state.loading || !store.hostsLoaded}
                >
                  Create
                </button>
              </form>
            </fieldset>
          </div>
        );
      }
    },
  ),
);

export default CommonHouseReservationsNew;
