import { useState } from "react";
import { inject, observer } from "mobx-react";
import ConfirmBar from "../confirm_bar";

const CloseButton = inject("store")(
  observer(({ store }) => {
    const [confirming, setConfirming] = useState(false);
    const meal = store.meal;

    const buttonClass = () => {
      if (store.mealLoading) {
        return "button-dark button-loader";
      }
      return meal && meal.closed ? "button-danger" : "button-success";
    };

    // Closing with a cook's cost still blank is allowed — costs are
    // often not known until after the shopping — but it needs a Yes:
    // the cook asserts "I know it's blank, I'll enter it later" instead
    // of parking a fake $1 to get past a gate.
    const missing = store.cooksMissingCost;
    const needsConfirm = meal && !meal.closed && missing.length > 0;

    const questionText =
      missing.length === 1
        ? `${missing[0]} hasn't entered a cost yet. Close the meal anyway?`
        : "Some cooks haven't entered a cost yet. Close the meal anyway?";

    return (
      <>
        <button
          onClick={() => {
            if (needsConfirm) {
              setConfirming(true);
              return;
            }
            store.toggleClosed();
          }}
          className={buttonClass()}
          disabled={(meal && meal.reconciled) || store.closedPending}
        >
          Open / Close Meal
        </button>
        {confirming && needsConfirm && (
          <ConfirmBar
            ariaLabel={questionText}
            question={
              <>
                {missing.length === 1 ? (
                  <>
                    <strong>{missing[0]}</strong> hasn&rsquo;t entered a cost
                    yet. Close the meal anyway?
                  </>
                ) : (
                  <>
                    Some cooks haven&rsquo;t entered a cost yet. Close the meal
                    anyway?
                  </>
                )}
                <span className="confirm-bar-note">
                  Costs can still be entered after the meal is closed.
                </span>
              </>
            }
            onYes={() => {
              setConfirming(false);
              store.toggleClosed();
            }}
            onDismiss={() => setConfirming(false)}
          />
        )}
      </>
    );
  }),
);

export default CloseButton;
