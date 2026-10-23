import { useEffect, useRef, useState } from "react";
import { useLocation, useNavigate, useParams } from "react-router";
import axios from "axios";
import handleAxiosError from "../../helpers/handle_axios_error";
import useFormMessages from "../../helpers/use_form_messages";
import toastStore from "../../stores/toast_store";
import FormMessages from "../modal_form/form_messages";

// Where this form reports whether it shows an error. Nothing reads it
// (see useFormMessages below).
function nobodyReads() {}

// What the page says when it has no token it can use. The server's
// answer for a link of the old kind says the same
// (ResidentsController::RETIRED_RESET_LINK).
export const RETIRED_LINK =
  "This password reset link no longer works. Please request a new one.";
export const NO_TOKEN =
  "Open the link in your password reset email again, or request a new one.";

// The token in the part of the address after the #, as the reset email
// writes it: /reset-password#token=... . A browser never sends that part
// to the server, so the token is in no request line and no log. Empty
// when there is none.
export function tokenFromHash(hash) {
  return new URLSearchParams(hash.replace(/^#/, "")).get("token") || "";
}

function ResidentsPasswordNew() {
  // A token in the path is a link mailed before 2026-10-23. Those tokens
  // were cleared when the link changed, so none of them can work.
  const { token: oldToken } = useParams();
  const location = useLocation();
  const navigate = useNavigate();
  // Read once, when the page opens. The effect below then takes it out
  // of the address, so it does not stay on a shared screen or in the
  // browser's history, and the page keeps it here.
  const [token] = useState(() => tokenFromHash(location.hash));

  const [ready, setReady] = useState(false);
  const [name, setName] = useState("");
  const [password, setPassword] = useState("");
  const [loading, setLoading] = useState(false);
  // Why the name could not be loaded, shown in place of "Loading...",
  // or null.
  const [failure, setFailure] = useState(null);
  // The form is in a dialog, and the stack of messages is drawn under an
  // open dialog, so a refused password shows inside the form (#137).
  // When a try works, the dialog closes, and the reasons earlier tries
  // got go with it. Nothing needs to know whether it shows an error.
  // This form shows only when signed out (login.jsx sends a signed-in
  // person on), and the idle timer leaves a signed-out page where it is
  // (helpers/screen_home.ts).
  const formMessages = useFormMessages(nobodyReads);

  // The submit handler outlives a navigation away from the page; the
  // mounted flag keeps it from setting state after unmount, like the
  // class's _isMounted guard.
  const mountedRef = useRef(true);

  useEffect(
    function () {
      mountedRef.current = true;
      // No request: the server could not use the link either. The
      // message stays up on the login page, like a refused link's.
      if (typeof oldToken !== "undefined" || token === "") {
        toastStore.show(
          typeof oldToken !== "undefined" ? RETIRED_LINK : NO_TOKEN,
          "error",
        );
        navigate("/", { replace: true });
        return function () {
          mountedRef.current = false;
        };
      }
      // Take the token out of the address. The page has it in state.
      navigate(
        { pathname: location.pathname, search: location.search },
        { replace: true },
      );
      axios
        .post(`/api/v1/residents/password-reset/name`, { reset_token: token })
        .then(function (response) {
          if (!mountedRef.current) return;
          setName(response.data.name);
          setReady(true);
        })
        .catch(function (error) {
          if (!mountedRef.current) return;
          if (error.response && error.response.status === 400) {
            // The server will not use this link: it answers 400 for a
            // link it does not know and for one that has expired
            // (ResidentsController#show_name). Show its reason; the
            // message stays up on the login page (issue #115).
            handleAxiosError(error);
            navigate("/");
          } else if (error.response) {
            // Any other answer, such as a 500 or a 429, says nothing
            // about the link, so the page that can still use it stays,
            // and shows the server's words. Reloading the page asks
            // for the name again.
            handleAxiosError(error, { show: (words) => setFailure(words) });
          } else {
            // No answer came back, so say so instead of "Loading..."
            // forever (issue #115).
            handleAxiosError(error, { silent: true });
            setFailure(
              "Could not load this page. Check your connection and try again.",
            );
          }
        });

      return function () {
        mountedRef.current = false;
      };
    },
    // Taking the token out of the address changes only the part after
    // the #, so this does not run again.
    [oldToken, token, navigate, location.pathname, location.search],
  );

  function handleSubmit(e) {
    e.preventDefault();
    setLoading(true);

    axios
      .post(`/api/v1/residents/password-reset/new`, {
        reset_token: token,
        password: password,
      })
      .then(function (response) {
        if (!mountedRef.current) return;
        setLoading(false);
        toastStore.show(response.data.message, "success");
        navigate("/");
      })
      .catch(function (error) {
        if (!mountedRef.current) return;
        setLoading(false);
        formMessages.showError(error);
      });
  }

  return (
    <div>
      {ready && (
        <form onSubmit={handleSubmit}>
          <fieldset className="w-100">
            <legend>Reset Password for {name}</legend>
            <FormMessages
              messages={formMessages.messages}
              close={formMessages.close}
            />
            <label className="w-75" htmlFor="new-password">
              <input
                id="new-password"
                name="password"
                type="password"
                placeholder="New Password"
                autoComplete="new-password"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                disabled={loading}
              />
            </label>
          </fieldset>

          <button
            type="submit"
            className={loading ? "button-loader" : ""}
            disabled={loading}
          >
            Submit
          </button>
        </form>
      )}
      {!ready && !failure && <h3>Loading...</h3>}
      {failure && <h3 className="text-warning">{failure}</h3>}
    </div>
  );
}

export default ResidentsPasswordNew;
