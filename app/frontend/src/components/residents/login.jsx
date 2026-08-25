import { useEffect, useRef, useState } from "react";
import { observer } from "mobx-react-lite";
import { Navigate, useLocation, useNavigate, useParams } from "react-router";
import axios from "axios";
import Cookie from "js-cookie";
import Modal from "react-modal";

import { useStore } from "../../helpers/store_context";
import handleAxiosError from "../../helpers/handle_axios_error";
import toastStore from "../../stores/toast_store";
import { communityNow } from "../../helpers/helpers";
import ResidentsPasswordNew from "./password_new";

// Where to send a signed-in resident when no redirect target was saved:
// today's calendar, in the community's timezone.
function defaultFrom() {
  return { pathname: `/calendar/all/${communityNow().format("YYYY-MM-DD")}` };
}

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
  const [loading, setLoading] = useState(false);

  // The requests outlive a navigation away; the flag keeps their
  // callbacks from setting state after unmount, like the class's
  // _isMounted.
  const mountedRef = useRef(true);
  // True from a successful login until the full page load replaces this page.
  const reloadingRef = useRef(false);
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

        if (response.status === 200) {
          // The page is about to be replaced by a full load (below), so
          // the loader stays up and the Navigate branch in render is
          // switched off first. Without both, the re-render finds the
          // token cookie, mounts the calendar client-side, and its first
          // requests are cancelled by the reload a few ms later — WebKit
          // reports that as an uncaught error (#80).
          reloadingRef.current = true;
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

          // The timezone cookie was just written (if present in the
          // response), so defaultFrom() picks up the fresh value here.
          var { from } = location.state || { from: defaultFrom() };
          window.location.href = from.pathname || from;
        } else {
          setLoading(false);
        }
      })
      .catch(function (error) {
        if (!mountedRef.current) return;
        setLoading(false);
        handleAxiosError(error);
      });
  }

  const { from } = location.state || { from: defaultFrom() };

  if (
    !reloadingRef.current &&
    typeof Cookie.get("token") !== "undefined" &&
    Cookie.get("token") !== "undefined"
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
            backgroundColor: "var(--powder-blue)",
          },
        }}
      >
        {modalOpen && <ResidentsPasswordNew />}
      </Modal>
    </div>
  );
});

export default ResidentsLogin;
