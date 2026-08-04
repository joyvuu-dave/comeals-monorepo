import { useEffect, useState } from "react";
import axios from "axios";
import handleAxiosError from "../../helpers/handle_axios_error";
import { toCommunityDayjs } from "../../helpers/helpers";

function MealHistoryShow({ id }) {
  const [date, setDate] = useState("loading...");
  const [items, setItems] = useState([]);
  const [ready, setReady] = useState(false);

  useEffect(
    function () {
      let cancelled = false;
      axios
        .get(`/api/v1/meals/${id}/history`)
        .then(function (response) {
          if (cancelled) return;
          if (response.status === 200) {
            setItems(response.data.items);
            setDate(toCommunityDayjs(response.data.date).format("ddd, MMM Do"));
            setReady(true);
          }
        })
        .catch(function (error) {
          handleAxiosError(error, { silent: true });
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
      {!ready && <h3>Loading...</h3>}
    </div>
  );
}

export default MealHistoryShow;
