import { useEffect, useState } from "react";
import axios from "axios";
import handleAxiosError from "../../helpers/handle_axios_error";

const styles = {
  main: {
    backgroundColor: "var(--offwhite)",
  },
};

// What the modal shows before an answer arrives.
const NOTHING_YET = {
  placeValue: null,
  residents: [],
  description: "",
  loaded: false,
  errored: false,
};

// Render the modal scaffold from the first frame. The residents list
// is fetched in an effect, once for each id; "Loading..." shows until
// the answer arrives.
//
// `id` is the database id from the URL. The number people see is the
// rotation's `place_value` (its position in date order), which is what
// the calendar bar shows. It comes back with the fetch, so the title
// reads "Rotation" alone until then. Showing `id` instead was a bug:
// the bar said "Rotation 104" and the modal said "Rotation 886".
function RotationsShow({ id }) {
  // Everything the modal shows, with the id it belongs to. The calendar
  // renders this modal without a key, so a new id in the URL gives this
  // same component a new id, and nothing of the old id may show for it.
  // So a new id starts over from NOTHING_YET during the render itself.
  // React then throws this render away and renders again at once with
  // that state, before anything is drawn (React's docs call this
  // "adjusting some state when a prop changes").
  const [shown, setShown] = useState({ id: id, ...NOTHING_YET });
  if (shown.id !== id) {
    setShown({ id: id, ...NOTHING_YET });
  }
  const { placeValue, residents, description, loaded, errored } = shown;

  useEffect(
    function () {
      let cancelled = false;
      axios
        .get(`/api/v1/rotations/${id}`)
        .then(function (response) {
          if (cancelled) return;
          // display_name is "unit - name", and residents.name is unique
          // (a case-insensitive index), so no two names compare equal.
          var sorted = [...response.data.residents].sort(function (a, b) {
            return a.display_name < b.display_name ? -1 : 1;
          });
          setShown({
            id: id,
            placeValue: response.data.place_value,
            residents: sorted,
            description: response.data.description,
            loaded: true,
            errored: false,
          });
        })
        .catch(function (error) {
          handleAxiosError(error, { silent: true });
          if (cancelled) return;
          setShown({ id: id, ...NOTHING_YET, errored: true });
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
