import { useEffect, useState } from "react";
import { observer } from "mobx-react-lite";
import { useStore } from "../../helpers/store_context";
import ConfirmBar from "../confirm_bar";

// What this uses in the DataStore.
interface CancelStore {
  // The meal on screen, or null when there is none. Its date is null
  // until its data arrives.
  readonly meal: {
    readonly id: number;
    readonly date: string | null;
    readonly reconciled: boolean;
    readonly cancelled: boolean;
  } | null;
  readonly mealLoading: boolean;
  // A Cancel or Restore is on its way.
  readonly cancelledPending: boolean;
  // A cost typed on the page is not on the server yet.
  billsPendingFor(mealId: number): boolean;
  setCancelled(mealId: number, cancelled: boolean): void;
}

// What an open question asks: Cancel or Restore, on which meal.
interface Asking {
  mealId: number;
  cancel: boolean;
}

// Cancel the dinner, or restore it (ADR 0011 rule 11). Anyone on the
// meal page can do either, each after a Yes. A settled dinner shows
// neither: it can't change any more. Neither does a meal whose data has
// not arrived yet (no date): the page does not know its state.
const CancelButton = observer(() => {
  // useStore is JavaScript, so TypeScript knows nothing of the store.
  const store = useStore() as CancelStore;
  // null when no question is open.
  const [asking, setAsking] = useState<Asking | null>(null);
  const meal = store.meal;
  const shown = !!meal && meal.date !== null && !meal.reconciled;
  const cancel = shown && !meal.cancelled;

  // A live update can cancel or restore the dinner, or settle it, while
  // the question is open, and the arrow keys can move the page to
  // another meal. The question is then about something that is done or
  // not on screen, so it goes away for good, and does not come back if
  // the page comes back.
  const stillAsking =
    shown &&
    asking !== null &&
    asking.mealId === meal.id &&
    asking.cancel === cancel;
  useEffect(
    function () {
      if (asking !== null && !stillAsking) setAsking(null);
    },
    [asking, stillAsking],
  );

  if (!shown) {
    return null;
  }

  // A cost typed on this page is saved 2 seconds after typing stops. A
  // Cancel sent before that save would be taken, and the cost refused
  // after it. Waiting for the save lets the server see the cost first
  // and refuse the Cancel instead, with its sentence.
  const disabled =
    store.mealLoading ||
    store.cancelledPending ||
    (cancel && store.billsPendingFor(meal.id));

  const question = cancel ? "Cancel this dinner?" : "Restore this dinner?";

  return (
    <>
      <button
        type="button"
        className="button-link text-secondary"
        onClick={() => setAsking({ mealId: meal.id, cancel })}
        disabled={disabled}
        aria-label={cancel ? "Cancel this dinner" : "Restore this dinner"}
      >
        {cancel ? "Cancel" : "Restore"}
      </button>
      {stillAsking && (
        <ConfirmBar
          ariaLabel={question}
          question={
            <>
              {question}
              <span className="confirm-bar-note">
                {cancel
                  ? "Sign-ups stay, and nobody is charged. It can be restored until it is settled."
                  : "Sign-ups, guests and costs can change again."}
              </span>
            </>
          }
          onYes={() => {
            setAsking(null);
            store.setCancelled(meal.id, cancel);
          }}
          onDismiss={() => setAsking(null)}
        />
      )}
    </>
  );
});

export default CancelButton;
