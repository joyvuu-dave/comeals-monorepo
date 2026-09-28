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
// (#110). When a retry is running, that is what the notice says.
const LoadStatus = observer(() => {
  const store = useStore();
  const navigate = useNavigate();

  const backToCalendar = (
    <button
      type="button"
      className="button"
      onClick={() =>
        navigate(`/calendar/all/${communityNow().format("YYYY-MM-DD")}`)
      }
    >
      Back to calendar
    </button>
  );

  let role;
  let message;
  let button;
  if (store.mealLoadNotFound) {
    role = "alert";
    message = "This meal could not be found.";
    button = backToCalendar;
  } else if (store.mealLoadFailed) {
    role = "status";
    message = <>Trouble loading this meal. Retrying&hellip;</>;
    button = (
      <button
        type="button"
        className="button"
        onClick={() => store.retryMealLoadNow()}
      >
        Retry now
      </button>
    );
  } else if (store.mealLoadBroken) {
    role = "alert";
    message = "Something went wrong showing this meal.";
    button = backToCalendar;
  } else {
    return null;
  }

  return (
    <div className="confirm-bar-anchor">
      <div className="confirm-bar" role={role}>
        <span className="confirm-bar-question">{message}</span>
        <span className="confirm-bar-buttons">{button}</span>
      </div>
    </div>
  );
});

export default LoadStatus;
