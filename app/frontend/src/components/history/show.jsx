import { useEffect, useState } from "react";
import axios from "axios";
import handleAxiosError from "../../helpers/handle_axios_error";
import { toCommunityDayjs } from "../../helpers/helpers";

function MealHistoryShow({ id }) {
  const [date, setDate] = useState("loading...");
  const [items, setItems] = useState([]);
  const [ready, setReady] = useState(false);
  const [errored, setErrored] = useState(false);

  useEffect(
    function () {
      let cancelled = false;
      axios
        .get(`/api/v1/meals/${id}/history`)
        .then(function (response) {
          if (cancelled) return;
          setItems(response.data.items);
          setDate(toCommunityDayjs(response.data.date).format("ddd, MMM Do"));
          setReady(true);
          // A failure for the id shown before no longer applies.
          setErrored(false);
        })
        .catch(function (error) {
          handleAxiosError(error, { silent: true });
          if (cancelled) return;
          // Say so, like the rotation modal, instead of "Loading..."
          // forever (issue #115). A history shown for the id before
          // is not this meal's.
          setReady(false);
          setErrored(true);
        });

      return function () {
        cancelled = true;
      };
    },
    [id],
  );

  return (
    <div>
      {ready && (
        <div>
          <div className="flex center">
            <h1 className="cell">{date}</h1>
          </div>
          <table className="table-striped background-white">
            <thead>
              <tr>
                <th className="background-white sticky-header">ID</th>
                <th className="background-white sticky-header">User</th>
                <th className="background-white sticky-header">Action</th>
                <th className="background-white sticky-header">Time</th>
              </tr>
            </thead>
            <tbody>
              {items.map((audit) => {
                return (
                  <tr key={audit.id}>
                    <td>{audit.id}</td>
                    <td>{audit.user_name}</td>
                    <td>{audit.description}</td>
                    <td>
                      {toCommunityDayjs(audit.display_time).format(
                        "ddd MMM D, h:mm a",
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
      {!ready && !errored && <h3>Loading...</h3>}
      {errored && <h3 className="text-warning">Failed to load history.</h3>}
    </div>
  );
}

export default MealHistoryShow;
