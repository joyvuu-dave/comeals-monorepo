import { useEffect, useState } from "react";
import axios from "axios";
import handleAxiosError from "../../helpers/handle_axios_error";

const styles = {
  main: {
    backgroundColor: "#ebebe4",
  },
};

// Render the modal scaffold — including the title, which we already know
// from props — from the first frame. The residents list fetches in a
// mount effect; skeleton covers the small latency gap.
function RotationsShow({ id }) {
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
    <div style={styles.main} data-populated={loaded ? "true" : undefined}>
      <div className="flex center">
        <u className="cell">
          <h1>{`Rotation ${id}`}</h1>
        </u>
      </div>
      <br />
      <div className="flex center">
        <h2 className="cell nine text-success">{description}</h2>
      </div>
      <br />
      {!loaded && !errored && <h3>Loading...</h3>}
      {errored && <h3 className="text-warning">Failed to load rotation.</h3>}
      {loaded && (
        <ul>
          {residents.map((resident) =>
            resident.signed_up ? (
              <s key={resident.id}>
                <li className="text-muted">{resident.display_name}</li>
              </s>
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
