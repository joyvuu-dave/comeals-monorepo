import { useEffect, useState } from "react";
import axios from "axios";
import handleAxiosError from "../../helpers/handle_axios_error";

const styles = {
  main: {
    backgroundColor: "var(--offwhite)",
  },
};

// Render the modal scaffold from the first frame. The residents list
// fetches in a mount effect; skeleton covers the small latency gap.
//
// `id` is the database id from the URL. The number people see is the
// rotation's `place_value` (its position in date order), which is what
// the calendar bar shows. It comes back with the fetch, so the title
// reads "Rotation" alone until then. Showing `id` instead was a bug:
// the bar said "Rotation 104" and the modal said "Rotation 886".
function RotationsShow({ id }) {
  const [placeValue, setPlaceValue] = useState(null);
  const [residents, setResidents] = useState([]);
  const [description, setDescription] = useState("");
  const [loaded, setLoaded] = useState(false);
  const [errored, setErrored] = useState(false);

  useEffect(
    function () {
      let cancelled = false;
      axios
        .get(`/api/v1/rotations/${id}`)
        .then(function (response) {
          if (cancelled) return;
          if (response.status === 200) {
            var sorted = [...response.data.residents].sort(function (a, b) {
              if (a.display_name < b.display_name) return -1;
              if (a.display_name > b.display_name) return 1;
              return 0;
            });
            setPlaceValue(response.data.place_value);
            setResidents(sorted);
            setDescription(response.data.description);
            setLoaded(true);
          }
        })
        .catch(function (error) {
          handleAxiosError(error, { silent: true });
          if (cancelled) return;
          setErrored(true);
        });

      return function () {
        cancelled = true;
      };
    },
    [id],
  );

  return (
    // tabIndex makes the modal body focusable. Unlike the form modals,
    // this one has no inputs or buttons, so without it a keyboard user
    // could not focus the modal to scroll a long resident list.
    <div
      style={styles.main}
      tabIndex={0}
      data-populated={loaded ? "true" : undefined}
    >
      <div className="flex center">
        <u className="cell">
          <h1>{placeValue === null ? "Rotation" : `Rotation ${placeValue}`}</h1>
        </u>
      </div>
      <br />
      {/* No h2 until the fetch fills it in — an empty heading fails
          the empty-heading accessibility rule. */}
      <div className="flex center">
        {description !== "" && (
          <h2 className="cell nine text-success">{description}</h2>
        )}
      </div>
      <br />
      {!loaded && !errored && <h3>Loading...</h3>}
      {errored && <h3 className="text-warning">Failed to load rotation.</h3>}
      {loaded && (
        <ul>
          {residents.map((resident) =>
            resident.signed_up ? (
              // The strike-through goes inside the li — a ul may only
              // contain li elements, so <s><li>…</li></s> is invalid.
              <li key={resident.id} className="text-muted">
                <s>{resident.display_name}</s>
              </li>
            ) : (
              <li key={resident.id} className="text-bold text-italic">
                {resident.display_name}
              </li>
            ),
          )}
        </ul>
      )}
    </div>
  );
}

export default RotationsShow;
