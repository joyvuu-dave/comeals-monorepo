import { observer } from "mobx-react-lite";
import { useNavigate } from "react-router";
import { useStore } from "../../helpers/store_context";
import dayjs from "dayjs";

// The honest state of a meal load that failed. It floats over the page
// the same way the ConfirmBar popover does — absolutely positioned
// under a zero-height anchor, so nothing on the page moves when it
// appears or leaves.
//
// A retryable failure (network, 5xx) says so and keeps retrying on its
// own — the button is for a person who is watching and wants it now.
// A 404 is permanent: no retry can conjure a deleted meal, so it
// offers the way back instead.
const LoadStatus = observer(() => {
  const store = useStore();
  const navigate = useNavigate();

  if (!store.mealLoadFailed && !store.mealLoadNotFound) {
    return null;
  }

  const notFound = store.mealLoadNotFound;
  return (
    <div className="confirm-bar-anchor">
      <div className="confirm-bar" role={notFound ? "alert" : "status"}>
        <span className="confirm-bar-question">
          {notFound ? (
            "This meal could not be found."
          ) : (
            <>Trouble loading this meal. Retrying&hellip;</>
          )}
        </span>
        <span className="confirm-bar-buttons">
          {notFound ? (
            <button
              type="button"
              className="button"
              onClick={() =>
                navigate(
                  `/calendar/all/${dayjs(new Date()).format("YYYY-MM-DD")}`,
                )
              }
            >
              Back to calendar
            </button>
          ) : (
            <button
              type="button"
              className="button"
              onClick={() => store.retryMealLoadNow()}
            >
              Retry now
            </button>
          )}
        </span>
      </div>
    </div>
  );
});

export default LoadStatus;
