import { useEffect, useRef, useState } from "react";
import { useNavigate, useParams } from "react-router";
import axios from "axios";
import handleAxiosError from "../../helpers/handle_axios_error";
import useFormMessages from "../../helpers/use_form_messages";
import toastStore from "../../stores/toast_store";
import FormMessages from "../modal_form/form_messages";

function ResidentsPasswordNew() {
  const { token } = useParams();
  const navigate = useNavigate();

  const [ready, setReady] = useState(false);
  const [name, setName] = useState("");
  const [password, setPassword] = useState("");
  const [loading, setLoading] = useState(false);
  const [errored, setErrored] = useState(false);
  // The form is in a dialog, and the stack of messages is drawn under an
  // open dialog, so a refused password shows inside the form (#137).
  // When a try works, the dialog closes, and the reasons earlier tries
  // got go with it.
  const formMessages = useFormMessages();

  // The submit handler outlives a navigation away from the page; the
  // mounted flag keeps it from setting state after unmount, like the
  // class's _isMounted guard.
  const mountedRef = useRef(true);

  useEffect(
    function () {
      mountedRef.current = true;
      axios
        .get(`/api/v1/residents/name/${token}`)
        .then(function (response) {
          if (!mountedRef.current) return;
          setName(response.data.name);
          setReady(true);
        })
        .catch(function (error) {
          if (!mountedRef.current) return;
          if (error.response) {
            // The server will not use this link. Show its reason; the
            // toast stays up on the login page (issue #115).
            handleAxiosError(error);
            navigate("/");
          } else {
            // No answer came back, so say so instead of "Loading..."
            // forever (issue #115).
            handleAxiosError(error, { silent: true });
            setErrored(true);
          }
        });

      return function () {
        mountedRef.current = false;
      };
    },
    [token, navigate],
  );

  function handleSubmit(e) {
    e.preventDefault();
    setLoading(true);

    axios
      .post(`/api/v1/residents/password-reset/${token}`, {
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
      {!ready && !errored && <h3>Loading...</h3>}
      {errored && (
        <h3 className="text-warning">
          Could not load this page. Check your connection and try again.
        </h3>
      )}
    </div>
  );
}

export default ResidentsPasswordNew;
