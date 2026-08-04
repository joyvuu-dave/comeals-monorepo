import { useEffect, useRef, useState } from "react";
import { useNavigate, useParams } from "react-router";
import axios from "axios";
import handleAxiosError from "../../helpers/handle_axios_error";
import toastStore from "../../stores/toast_store";

function ResidentsPasswordNew() {
  const { token } = useParams();
  const navigate = useNavigate();

  const [ready, setReady] = useState(false);
  const [name, setName] = useState("");
  const [password, setPassword] = useState("");
  const [loading, setLoading] = useState(false);

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
          if (response.status === 200) {
            setName(response.data.name);
            setReady(true);
          }
        })
        .catch(function (error) {
          handleAxiosError(error, { silent: true });
          if (!mountedRef.current) return;
          if (error.response) {
            navigate("/");
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
        if (response.status === 200) {
          if (response.data.message) {
            toastStore.replaceAll(response.data.message, "success");
          }
          navigate("/");
        }
      })
      .catch(function (error) {
        if (!mountedRef.current) return;
        setLoading(false);
        handleAxiosError(error);
      });
  }

  return (
    <div>
      {ready && (
        <form onSubmit={handleSubmit}>
          <fieldset className="w-100">
            <legend>Reset Password for {name}</legend>
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
      {!ready && <h3>Loading...</h3>}
    </div>
  );
}

export default ResidentsPasswordNew;
