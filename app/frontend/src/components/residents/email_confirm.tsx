import { useEffect, useState } from "react";
import { useLocation, useNavigate } from "react-router";
import axios from "axios";
import handleAxiosError from "../../helpers/handle_axios_error";
import toastStore from "../../stores/toast_store";
import { tokenFromHash } from "./password_new";

export const NO_TOKEN =
  "Open the link in your email change email again, or change your email again from your profile.";

// The page the link in an email change email opens:
// /confirm-email#token=... (ResidentMailer#email_change_link_email). The
// token is after the #, which a browser never sends to the server, so it
// is in no request line and no log. The page posts it, shows what the
// server said, and goes on to "/": the calendar when this browser is
// signed in, the sign-in page when it is not. The link works the same
// either way. Opening it shows the person reads the new address, and
// that is all the server needs.
function ResidentsEmailConfirm() {
  const location = useLocation();
  const navigate = useNavigate();
  // Read once, when the page opens. The address is changed to "/" below,
  // so the token does not stay in the browser's history.
  const [token] = useState<string>(() => tokenFromHash(location.hash));

  useEffect(
    function () {
      if (token === "") {
        toastStore.show(NO_TOKEN, "error");
        navigate("/", { replace: true });
        return;
      }
      axios
        .post<{ message: string }>("/api/v1/profile/email-confirm", {
          email_token: token,
        })
        .then(function (response) {
          toastStore.show(response.data.message, "success");
        })
        .catch(function (error: unknown) {
          handleAxiosError(error);
        })
        .then(function () {
          navigate("/", { replace: true });
        });
    },
    [token, navigate],
  );

  return <h3>Changing your email...</h3>;
}

export default ResidentsEmailConfirm;
