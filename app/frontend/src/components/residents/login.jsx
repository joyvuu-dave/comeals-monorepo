import { useEffect, useRef, useState } from "react";
import { observer } from "mobx-react";
import { Navigate, useLocation, useNavigate, useParams } from "react-router";
import axios from "axios";
import Cookie from "js-cookie";
import dayjs from "dayjs";
import Modal from "react-modal";

import { useStore } from "../../helpers/store_context";
import handleAxiosError from "../../helpers/handle_axios_error";
import toastStore from "../../stores/toast_store";
import { communityNow, getCommunityTimezone } from "../../helpers/helpers";
import ResidentsPasswordNew from "./password_new";

const styles = {
  box: {
    marginRight: "auto",
    marginLeft: "auto",
    paddingRight: "15px",
    paddingLeft: "15px",
    width: "100%",
  },
};

Modal.setAppElement("#root");

const ResidentsLogin = observer(() => {
  const store = useStore();
  const params = useParams();
  const location = useLocation();
  const navigate = useNavigate();

  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [redirectToReferrer] = useState(false);
  const [loading, setLoading] = useState(false);

  // The requests outlive a navigation away; the flag keeps their
  // callbacks from setting state after unmount, like the class's
  // _isMounted.
  const mountedRef = useRef(true);
  useEffect(function () {
    mountedRef.current = true;
    return function () {
      mountedRef.current = false;
    };
  }, []);

  const modalOpen =
    params.modal === "reset-password" && typeof params.token !== "undefined";

  function handleCloseModal() {
    navigate("/");
  }

  function handleResetPassword() {
    const trimmedEmail = (email || "").trim();
    if (!trimmedEmail) {
      toastStore.replaceAll("Email required.", "error");
      return;
    }

    setLoading(true);
    axios
      .post(`/api/v1/residents/password-reset`, { email: trimmedEmail })
      .then(function (response) {
        if (!mountedRef.current) return;
        setLoading(false);
        if (response.status === 200 && response.data.message) {
          toastStore.replaceAll(response.data.message, "success");
        }
      })
      .catch(function (error) {
        if (!mountedRef.current) return;
        setLoading(false);
        handleAxiosError(error);
      });
  }

  function handleSubmit(e) {
    e.preventDefault();
    setLoading(true);

    axios
      .post(`/api/v1/residents/token`, {
        email: email,
        password: password,
      })
      .then(function (response) {
        if (!mountedRef.current) return;
        setLoading(false);

        if (response.status === 200) {
          Cookie.set("token", response.data.token, {
            expires: 7300,
          });
          Cookie.set("community_id", response.data.community_id, {
            expires: 7300,
          });
          Cookie.set("resident_id", response.data.resident_id, {
            expires: 7300,
          });
          Cookie.set("username", response.data.username, {
            expires: 7300,
          });
          if (response.data.timezone) {
            Cookie.set("timezone", response.data.timezone, {
              expires: 7300,
            });
          }

          // Cookie was just written (if present in the response), so
          // getCommunityTimezone() picks up the fresh value here.
          var tz = getCommunityTimezone();
          var { from } = location.state || {
            from: {
              pathname: "/calendar/all/" + dayjs().tz(tz).format("YYYY-MM-DD"),
            },
          };
          window.location.href = from.pathname || from;
        }
      })
      .catch(function (error) {
        if (!mountedRef.current) return;
        setLoading(false);
        handleAxiosError(error);
      });
  }

  const { from } = location.state || {
    from: {
      pathname: `/calendar/all/${communityNow().format("YYYY-MM-DD")}`,
    },
  };

  if (
    redirectToReferrer ||
    (typeof Cookie.get("token") !== "undefined" &&
      Cookie.get("token") !== "undefined")
  ) {
    return <Navigate to={from} replace />;
  }

  return (
    <div>
      <header className="flex space-between header">
        <h2 className="pad-l-sm">Comeals</h2>
        {store.isOnline ? (
          <span className="online">ONLINE</span>
        ) : (
          <span className="offline">OFFLINE</span>
        )}
      </header>
      <div style={styles.box}>
        <br />
        <div>
          <form onSubmit={handleSubmit}>
            <fieldset className="login-box">
              <legend>Resident Login</legend>
              <label className="w-80" htmlFor="login-email">
                <input
                  id="login-email"
                  name="email"
                  type="email"
                  placeholder="Email"
                  autoCapitalize="none"
                  autoComplete="username"
                  disabled={loading}
                  aria-label="email"
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                />
              </label>
              <br />
              <label className="w-80" htmlFor="login-password">
                <input
                  id="login-password"
                  name="password"
                  type="password"
                  placeholder="Password"
                  autoComplete="current-password"
                  disabled={loading}
                  aria-label="password"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                />
              </label>
            </fieldset>

            <button
              className={loading ? "button-loader" : ""}
              type="submit"
              disabled={loading}
            >
              Submit
            </button>
          </form>
          <br />
          <button
            type="button"
            className="text-black button-link"
            disabled={loading}
            onClick={handleResetPassword}
          >
            Reset your password
          </button>
        </div>
      </div>
      <Modal
        isOpen={modalOpen}
        contentLabel="Login Modal"
        onRequestClose={handleCloseModal}
        style={{
          content: {
            backgroundColor: "#CCDEEA",
          },
        }}
      >
        {modalOpen && (
          <ResidentsPasswordNew handleCloseModal={handleCloseModal} />
        )}
      </Modal>
    </div>
  );
});

export default ResidentsLogin;
