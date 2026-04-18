import { Component } from "react";
import DayPickerInputWrapper from "../common/day_picker_input";
import dayjs from "dayjs";
import axios from "axios";
import Cookie from "js-cookie";
import { inject, observer } from "mobx-react";
import handleAxiosError from "../../helpers/handle_axios_error";
import { FontAwesomeIcon } from "@fortawesome/react-fontawesome";
import { faTimes } from "@fortawesome/free-solid-svg-icons";

// No `ready` gate: render the full form from the first frame. The host
// select is reactively bound to `store.hosts` (populated on mount via
// store.ensureHosts()), so the dropdown lights up as soon as the cached
// or freshly-fetched list is available — and stays in sync in real time
// via the Pusher `community-<id>-residents` subscription.
const GuestRoomReservationsNew = inject("store")(
  observer(
    class GuestRoomReservationsNew extends Component {
      constructor(props) {
        super(props);
        this.handleDayChange = this.handleDayChange.bind(this);

        this.state = {
          communityId: Cookie.get("community_id"),
          resident_id: "",
          day: null,
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
        axios
          .post(
            `/api/v1/guest-room-reservations?community_id=${
              self.state.communityId
            }&token=${Cookie.get("token")}`,
            {
              resident_id: self.state.resident_id,
              date: self.state.day
                ? dayjs(self.state.day).format("YYYY-MM-DD")
                : null,
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
        const hosts = store.hosts;
        return (
          <div>
            <div className="flex">
              <h2>Guest Room Reservation</h2>
              <FontAwesomeIcon
                icon={faTimes}
                size="2x"
                className="close-button"
                onClick={this.props.handleCloseModal}
              />
            </div>
            {/* `data-populated` reflects whether the data needed to fully use
                the form (the host list) is available. Present at first paint
                when the cache is warm; absent only while a cold fetch is in
                flight. Consumed by the modal perf benchmark as an
                apples-to-apples "user can see real data" signal. */}
            <fieldset data-populated={store.hostsLoaded ? "true" : undefined}>
              <legend>New</legend>
              <form onSubmit={(e) => this.handleSubmit(e)}>
                <label>Host</label>
                <select
                  id="local.resident_id"
                  value={this.state.resident_id}
                  onChange={(e) =>
                    this.setState({ resident_id: e.target.value })
                  }
                  disabled={this.state.loading}
                >
                  <option />
                  {hosts.map((host) => (
                    <option key={host.id} value={host.id}>
                      {host.unitName} - {host.name}
                    </option>
                  ))}
                </select>
                <br />

                <label>Day</label>
                <br />
                <div
                  style={
                    this.state.loading
                      ? { pointerEvents: "none", opacity: 0.5 }
                      : undefined
                  }
                >
                  <DayPickerInputWrapper
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

export default GuestRoomReservationsNew;
