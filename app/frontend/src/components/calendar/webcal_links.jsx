import { useEffect, useState } from "react";
import Cookie from "js-cookie";
import axios from "axios";
import handleAxiosError from "../../helpers/handle_axios_error";

function WebcalLinks() {
  const [residentId, setResidentId] = useState(Cookie.get("resident_id"));
  const [ready, setReady] = useState(false);

  useEffect(function () {
    if (typeof Cookie.get("resident_id") === "undefined") {
      let cancelled = false;
      axios
        .get(`/api/v1/residents/id`)
        .then(function (response) {
          if (cancelled) return;
          if (response.status === 200) {
            Cookie.set("resident_id", response.data, {
              expires: 7300,
            });

            setResidentId(response.data);
            setReady(true);
          }
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
      {ready && (
        <a href={`webcal://${apiHost}/api/v1/residents/${residentId}/ical.ics`}>
          Subscribe to My Meals
        </a>
      )}
    </div>
  );
}

export default WebcalLinks;
