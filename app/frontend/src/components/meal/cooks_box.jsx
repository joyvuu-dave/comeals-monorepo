import { useRef, useState } from "react";
import { observer } from "mobx-react-lite";
import { useStore } from "../../helpers/store_context";
import ConfirmBar from "../confirm_bar";
import { isZeroAmountString, toDisplayAmountString } from "../../helpers/money";

const styles = {
  main: {
    gridArea: "a4",
    border: "1px solid",
  },
  select: {
    marginLeft: "1px",
    opacity: "1",
  },
  // The cost field of a row with no cook takes no cost (#145), and it
  // is dimmed like the No cost switch next to it. On a touch screen the
  // not-allowed cursor does not show, so the dimming is what says the
  // field is off (#113).
  costWithoutCook: {
    marginLeft: "1px",
    opacity: "0.5",
  },
};

// A cook every row's menu offers: one who is active and can cook.
function offeredInEveryMenu(resident) {
  return resident.active === true && resident.can_cook === true;
}

// The cooks a row's menu offers: every active resident who can cook,
// the row's cook now, and the row's cook when the meal was loaded,
// except a cook picked in another row. A save names each cook once, so
// a cook picked in two rows could not be saved (billEditsOf).
//
// A cook who was retired, or whose "can cook" was turned off, after
// cooking keeps their bill (#91), and only their own row offers them.
// Picking another name in their row, or the blank, sends a save that
// removes their bill, so that pick asks first. Their row offers them
// even after a Yes, so the person can pick them again, and that save
// adds the bill back. After the page loads the meal again, no menu
// offers them, and only an admin can make them a cook again.
function cookChoices(store, bill) {
  const pickedElsewhere = new Set(
    Array.from(store.bills.values())
      .filter((other) => other !== bill)
      .map((other) => other.resident_id),
  );
  return Array.from(store.residents.values()).filter(
    (resident) =>
      resident.id === bill.resident_id ||
      (!pickedElsewhere.has(resident.id) &&
        (resident.id === bill.loadedCookId || offeredInEveryMenu(resident))),
  );
}

// True when a pick in the row's menu removes a bill that only an admin
// can add back once the meal loads again: the row's cook is one no other
// menu offers, and the server has their bill for this row (the row's
// base). If the server does not have it yet, the pick only undoes a
// pick that was not saved, and removes nothing.
function pickRemovesBillOnlyAdminCanAddBack(bill) {
  const cook = bill.resident;
  return (
    cook !== null && cook.id === bill.baseCookId && !offeredInEveryMenu(cook)
  );
}

const BillEdit = observer(({ bill }) => {
  const store = useStore();
  // Turning on "no cost" erases a typed cost, and on a shared screen
  // that click can come from anyone. So the switch asks first.
  const [confirmingNoCost, setConfirmingNoCost] = useState(false);
  // A pick in the cook menu that waits for a Yes: the menu's value, or
  // null when no pick is waiting.
  const [pickToConfirm, setPickToConfirm] = useState(null);
  const confirmKeyRef = useRef(0);

  // Bills freeze at reconciliation, not at close — the server has
  // always allowed bill edits on a closed meal. Costs are often not
  // known until after the shopping, which is often after the close.
  // No meal loaded also freezes: rows must never be editable while
  // there is no meal to save them to. So does a meal loading again
  // after a bills save for it failed: until it arrives, a row may show
  // what the server does not have, and an edit typed on it would be
  // built on that (loadMealAgain).
  const frozen = !store.meal || store.meal.reconciled || store.mealLoading;

  // A question goes away when the row freezes: a Yes would change a row
  // that may show what the server does not have. When the meal arrives,
  // the rows are made again, and a new row asks nothing.
  const askingNoCost =
    confirmingNoCost && !frozen && !isZeroAmountString(bill.amount);
  const askingToRemoveCook = pickToConfirm !== null && !frozen;

  return (
    <div className="confirm-bar-anchor">
      <div className="input-group">
        <select
          value={bill.resident_id}
          onChange={(e) => {
            // Every pick closes the no-cost question. A keyboard can reach
            // this menu while that question is open, with no click to
            // close it, and the question names the row's cook: after a
            // pick it would name another cook, or no cook at all.
            setConfirmingNoCost(false);
            // The menu keeps showing the row's cook until the Yes, because
            // its value comes from the row.
            if (pickRemovesBillOnlyAdminCanAddBack(bill)) {
              confirmKeyRef.current += 1;
              setPickToConfirm(e.target.value);
              return;
            }
            bill.setResident(e.target.value);
          }}
          onBlur={() => store.flushPendingBillsSave()}
          style={styles.select}
          disabled={frozen}
          aria-label="Select meal cook"
        >
          <option value={""} key={-1}>
            ¯\_(ツ)_/¯
          </option>
          {cookChoices(store, bill).map((resident) => (
            <option value={resident.id} key={resident.id}>
              {resident.name}
            </option>
          ))}
        </select>
        <div className="input-group">
          <span className="input-addon">$</span>
          <input
            type="number"
            min="0"
            max="9999.99"
            step="0.01"
            value={bill.amount}
            onChange={(e) => {
              // Typing a cost closes the no-cost question, for the same
              // reason a pick in the menu does: the question names the
              // row's cost.
              setConfirmingNoCost(false);
              // setAmount refuses input that breaks the whole-cents grammar.
              // On refusal the store is unchanged, so React skips the
              // re-render — put the stored amount back in the DOM by hand.
              const landed = bill.setAmount(e.target.value);
              if (landed !== e.target.value) {
                e.target.value = landed;
              }
            }}
            onBlur={() => {
              bill.normalizeAmountDisplay();
              store.flushPendingBillsSave();
            }}
            style={bill.resident_id ? styles.select : styles.costWithoutCook}
            className={bill.costPending ? "cost-pending" : ""}
            // A save names cooks, so a cost in a row with no cook would
            // never be sent, and the next load of the meal would make
            // the row again without it (#145).
            disabled={frozen || !bill.resident_id}
            placeholder={bill.costPending ? "pending" : undefined}
            aria-label="Set meal cost"
          />
        </div>
        <span className="switch">
          No cost
          <input
            id={`no_cost_switch-${bill.id}`}
            type="checkbox"
            className="switch"
            checked={bill.no_cost}
            onChange={() => {
              // Turning no cost on erases a typed cost — that needs a
              // Yes first. Turning it off, or on with nothing typed,
              // destroys nothing and flips right away.
              if (!bill.no_cost && !isZeroAmountString(bill.amount)) {
                confirmKeyRef.current += 1;
                setPickToConfirm(null);
                setConfirmingNoCost(true);
                return;
              }
              bill.toggleNoCost();
            }}
            onBlur={() => store.flushPendingBillsSave()}
            disabled={frozen || !bill.resident_id}
            aria-label={`No cost button for ${bill.id}`}
          />
          <label htmlFor={`no_cost_switch-${bill.id}`} />
        </span>
      </div>
      {askingNoCost && (
        <ConfirmBar
          key={confirmKeyRef.current}
          armMs={400}
          ariaLabel={`Erase ${bill.resident.plainName}'s $${toDisplayAmountString(bill.amount)}?`}
          question={
            <>
              Erase{" "}
              <strong>
                {bill.resident.plainName}&rsquo;s $
                {toDisplayAmountString(bill.amount)}
              </strong>
              ?
            </>
          }
          onYes={() => {
            setConfirmingNoCost(false);
            bill.toggleNoCost();
          }}
          onDismiss={() => setConfirmingNoCost(false)}
        />
      )}
      {askingToRemoveCook && (
        <ConfirmBar
          key={confirmKeyRef.current}
          armMs={400}
          // No goes on the left, under the menu that was just used.
          className="confirm-bar-left"
          ariaLabel={`Remove ${bill.resident.plainName} as a cook?`}
          question={
            <>
              Remove <strong>{bill.resident.plainName}</strong> as a cook?
              <span className="confirm-bar-note">
                After this page updates, only an admin can add{" "}
                {bill.resident.plainName} back.
              </span>
            </>
          }
          onYes={() => {
            setPickToConfirm(null);
            bill.setResident(pickToConfirm);
          }}
          onDismiss={() => setPickToConfirm(null)}
        />
      )}
    </div>
  );
});

const CooksBox = observer(() => {
  const store = useStore();
  return (
    <div className="offwhite button-border-radius" style={styles.main}>
      <div className="flex space-between title">
        <h2>Cooks</h2>
      </div>
      <div>
        {Array.from(store.bills.values()).map((bill) => (
          <BillEdit key={bill.id} bill={bill} />
        ))}
      </div>
    </div>
  );
});

export default CooksBox;
