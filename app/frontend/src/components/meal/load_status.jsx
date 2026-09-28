import { observer } from "mobx-react-lite";
import { useNavigate } from "react-router";
import { useStore } from "../../helpers/store_context";
import { communityNow } from "../../helpers/helpers";

// The honest state of a meal load that failed. It floats over the page
// the same way the ConfirmBar popover does — absolutely positioned
// under a zero-height anchor, so nothing on the page moves when it
// appears or leaves.
//
// A retryable failure (network, 5xx) says so and keeps retrying on its
// own — the button is for a person who is watching and wants it now.
// A 404 is permanent: no retry can conjure a deleted meal, so it
// offers the way back instead. So does an answer the page could not
// use: that is a bug, not a network state, so nothing retries it
// (#110).
const LoadStatus = observer(() => {
  const store = useStore();
  const navigate = useNavigate();

  if (
    !store.mealLoadFailed &&
    !store.mealLoadNotFound &&
    !store.mealLoadBroken
  ) {
    return null;
  }

  // One notice, even when two flags are up. A 404 shows first. A
  // running retry shows over an answer that could not be used: it is
  // the newer state.
  const notFound = store.mealLoadNotFound;
  const retrying = !notFound && store.mealLoadFailed;
  return (
    <div className="confirm-bar-anchor">
      <div className="confirm-bar" role={retrying ? "status" : "alert"}>
        <span className="confirm-bar-question">
          {notFound ? (
            "This meal could not be found."
          ) : retrying ? (
            <>Trouble loading this meal. Retrying&hellip;</>
          ) : (
            "Something went wrong showing this meal."
          )}
        </span>
        <span className="confirm-bar-buttons">
          {retrying ? (
            <button
              type="button"
              className="button"
              onClick={() => store.retryMealLoadNow()}
            >
              Retry now
            </button>
          ) : (
            <button
              type="button"
              className="button"
              onClick={() =>
                navigate(`/calendar/all/${communityNow().format("YYYY-MM-DD")}`)
              }
            >
              Back to calendar
            </button>
          )}
        </span>
      </div>
    </div>
  );
});

export default LoadStatus;
