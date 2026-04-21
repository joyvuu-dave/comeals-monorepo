import { Component } from "react";
import axios from "axios";
import handleAxiosError from "../../helpers/handle_axios_error";
import toastStore from "../../stores/toast_store";

class ResidentsPasswordReset extends Component {
  constructor(props) {
    super(props);

    this.state = {
      email: "",
      loading: false,
    };
  }

  componentDidMount() {
    this._isMounted = true;
  }

  componentWillUnmount() {
    this._isMounted = false;
  }

  handleSubmit(e) {
    e.preventDefault();
    this.setState({ loading: true });

    var self = this;
    axios
      .post(`/api/v1/residents/password-reset`, {
        email: self.state.email,
      })
      .then(function (response) {
        if (!self._isMounted) return;
        self.setState({ loading: false });
        if (response.status === 200) {
          if (response.data.message) {
            toastStore.addToast(response.data.message, "success");
          }
          self.props.history.push("/");
        }
      })
      .catch(function (error) {
        if (!self._isMounted) return;
        self.setState({ loading: false });
        handleAxiosError(error);
      });
  }

  render() {
    return (
      <form onSubmit={(e) => this.handleSubmit(e)}>
        <fieldset>
          <legend>Password Reset</legend>
          <label className="w-100" htmlFor="reset-email">
            <input
              id="reset-email"
              name="email"
              type="email"
              placeholder="Email"
              autoCapitalize="none"
              autoComplete="username"
              disabled={this.state.loading}
              value={this.state.email}
              onChange={(e) => this.setState({ email: e.target.value })}
            />
          </label>
        </fieldset>

        <button
          className={this.state.loading ? "button-loader" : ""}
          type="submit"
          disabled={this.state.loading}
        >
          Reset
        </button>
      </form>
    );
  }
}

export default ResidentsPasswordReset;
