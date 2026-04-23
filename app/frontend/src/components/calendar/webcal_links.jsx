import { Component } from "react";
import Cookie from "js-cookie";
import axios from "axios";
import handleAxiosError from "../../helpers/handle_axios_error";

class WebcalLinks extends Component {
  constructor(props) {
    super(props);

    this.state = {
      resident_id: Cookie.get("resident_id"),
      ready: false,
    };
  }

  componentDidMount() {
    this._isMounted = true;
    if (typeof this.state.resident_id === "undefined") {
      var self = this;
      axios
        .get(`/api/v1/residents/id`)
        .then(function (response) {
          if (!self._isMounted) return;
          if (response.status === 200) {
            Cookie.set("resident_id", response.data, {
              expires: 7300,
            });

            self.setState({
              resident_id: response.data,
              ready: true,
            });
          }
        })
        .catch(function (error) {
          handleAxiosError(error, { silent: true });
        });
    } else {
      this.setState({
        ready: true,
      });
    }
  }

  componentWillUnmount() {
    this._isMounted = false;
  }

  render() {
    var apiHost = window.location.host;

    return (
      <div className="flex space-between w-100">
        <a
          href={`webcal://${apiHost}/api/v1/communities/${Cookie.get(
            "community_id",
          )}/ical.ics`}
        >
          Subscribe to All Meals
        </a>
        {this.state.ready && (
          <a
            href={`webcal://${apiHost}/api/v1/residents/${
              this.state.resident_id
            }/ical.ics`}
          >
            Subscribe to My Meals
          </a>
        )}
      </div>
    );
  }
}

export default WebcalLinks;
