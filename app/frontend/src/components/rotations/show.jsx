import { Component } from "react";
import axios from "axios";
import Cookie from "js-cookie";
import handleAxiosError from "../../helpers/handle_axios_error";

const styles = {
  main: {
    backgroundColor: "#ebebe4",
  },
};

// Render the modal scaffold — including the title, which we already know
// from props — from the first frame. The residents list fetches in
// componentDidMount; skeleton covers the small latency gap.
class RotationsShow extends Component {
  constructor(props) {
    super(props);
    this.state = {
      residents: [],
      description: "",
      loaded: false,
      errored: false,
    };
  }

  componentDidMount() {
    this._isMounted = true;
    var self = this;
    axios
      .get(`/api/v1/rotations/${this.props.id}?token=${Cookie.get("token")}`)
      .then(function (response) {
        if (!self._isMounted) return;
        if (response.status === 200) {
          var sorted = [...response.data.residents].sort(function (a, b) {
            if (a.display_name < b.display_name) return -1;
            if (a.display_name > b.display_name) return 1;
            return 0;
          });
          self.setState({
            residents: sorted,
            description: response.data.description,
            loaded: true,
          });
        }
      })
      .catch(function (error) {
        handleAxiosError(error, { silent: true });
        if (!self._isMounted) return;
        self.setState({ errored: true });
      });
  }

  componentWillUnmount() {
    this._isMounted = false;
  }

  render() {
    return (
      <div
        style={styles.main}
        data-populated={this.state.loaded ? "true" : undefined}
      >
        <div className="flex center">
          <u className="cell">
            <h1>{`Rotation ${this.props.id}`}</h1>
          </u>
        </div>
        <br />
        <div className="flex center">
          <h2 className="cell nine text-success">{this.state.description}</h2>
        </div>
        <br />
        {!this.state.loaded && !this.state.errored && <h3>Loading...</h3>}
        {this.state.errored && (
          <h3 className="text-warning">Failed to load rotation.</h3>
        )}
        {this.state.loaded && (
          <ul>
            {this.state.residents.map((resident) =>
              resident.signed_up ? (
                <s key={resident.id}>
                  <li className="text-muted">{resident.display_name}</li>
                </s>
              ) : (
                <li key={resident.id} className="text-bold text-italic">
                  {resident.display_name}
                </li>
              ),
            )}
          </ul>
        )}
      </div>
    );
  }
}

export default RotationsShow;
