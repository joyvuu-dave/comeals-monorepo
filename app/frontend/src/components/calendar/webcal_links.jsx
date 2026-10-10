import { useEffect, useState } from "react";
import Cookie from "js-cookie";
import axios from "axios";
import handleAxiosError from "../../helpers/handle_axios_error";
import { communityId, signedIn } from "../../helpers/session";

function WebcalLinks() {
  const [residentId, setResidentId] = useState(Cookie.get("resident_id"));
  const [ready, setReady] = useState(false);

  useEffect(function () {
    if (typeof Cookie.get("resident_id") === "undefined") {
      // Logout removes every session cookie just before the page loads
      // "/" again, and a calendar can mount in between. With no token
      // the server can only answer 401, so nothing is asked (#153).
      if (!signedIn()) return;
      let cancelled = false;
      axios
        .get(`/api/v1/residents/id`)
        .then(function (response) {
          if (cancelled) return;
          Cookie.set("resident_id", response.data, {
            expires: 7300,
          });

          setResidentId(response.data);
          setReady(true);
        })
        .catch(function (error) {
          handleAxiosError(error, { silent: true });
        });
      return function () {
        cancelled = true;
      };
    } else {
      setReady(true);
    }
  }, []);

  // The same moment: with no community id there is no feed to link to,
  // and the link would name the community "undefined" (#153).
  var community = communityId();
  if (community === null) return null;

  var apiHost = window.location.host;

  return (
    <div className="flex space-between w-100">
      <a href={`webcal://${apiHost}/api/v1/communities/${community}/ical.ics`}>
        Subscribe to All Meals
      </a>
      {ready && (
        <a href={`webcal://${apiHost}/api/v1/residents/${residentId}/ical.ics`}>
          Subscribe to My Meals
        </a>
      )}
    </div>
  );
}

export default WebcalLinks;
