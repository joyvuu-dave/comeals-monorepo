import { Component } from "react";
import DayPickerInputWrapper from "../common/day_picker_input";
import dayjs from "dayjs";
import axios from "axios";
import { inject, observer } from "mobx-react";
import handleAxiosError from "../../helpers/handle_axios_error";
import ConfirmModal from "../app/confirm_modal";
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
const GuestRoomReservationsEdit = inject("store")(
  observer(
    class GuestRoomReservationsEdit extends Component {
      constructor(props) {
        super(props);
        this.handleDayChange = this.handleDayChange.bind(this);

        this.state = {
          loaded: false,
          event: {},
          resident_id: "",
          day: "",
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
          .get(`/api/v1/guest-room-reservations/${self.props.eventId}`)
          .then(function (response) {
            if (!self._isMounted) return;
            if (response.status === 200) {
              self.setState({
                event: response.data.event,
                loaded: true,
                resident_id: response.data.event.resident_id,
                day: response.data.event.date,
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
        axios
          .patch(
            `/api/v1/guest-room-reservations/${self.props.eventId}/update`,
            {
              resident_id: self.state.resident_id,
              date: self.state.day
                ? dayjs(self.state.day).format("YYYY-MM-DD")
                : null,
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
            `/api/v1/guest-room-reservations/${self.props.eventId}/delete`,
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
        const hosts = this.props.store.hosts;
        const disabled =
          this.state.loadingAction !== null || !this.state.loaded;
        // `data-populated` flips true only when the per-event fetch has
        // landed — Edit modals depend on both the hosts cache AND the
        // record payload, so waiting on both gives an honest "user can
        // see the actual data" signal for the benchmark.
        const populated = this.state.loaded && this.props.store.hostsLoaded;
        return (
          <div>
            <div className="flex">
              <h2>Guest Room Reservation</h2>
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
                <label htmlFor="guest-room-edit-host">Host</label>
                <select
                  id="guest-room-edit-host"
                  value={this.state.resident_id}
                  onChange={(e) =>
                    this.setState({ resident_id: e.target.value })
                  }
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
                    disabled
                      ? { pointerEvents: "none", opacity: 0.5 }
                      : undefined
                  }
                >
                  <DayPickerInputWrapper
                    id="guest-room-edit-day"
                    value={this.state.day}
                    onDayChange={this.handleDayChange}
                    inputDisabled={disabled}
                    disabledDays={
                      this.state.event.date
                        ? [
                            {
                              after: dayjs(this.state.event.date)
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

export default GuestRoomReservationsEdit;
