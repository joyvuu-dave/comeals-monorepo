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
};

// The cooks a row's menu offers: every active resident who can cook,
// the row's cook now, and the row's cook when the meal was loaded. A
// cook who was retired, or whose "can cook" was turned off, after
// cooking keeps their bill (#91), and only their own row offers them.
// Their row offers them even after someone picks another name there by
// mistake, so the person can pick them again. Otherwise the next save
// would leave them out, and the server would delete their bill.
function cookChoices(residents, bill) {
  return Array.from(residents.values()).filter(
    (resident) =>
      resident.id === bill.resident_id ||
      resident.id === bill.loadedCookId ||
      (resident.active === true && resident.can_cook === true),
  );
}

const BillEdit = observer(({ bill }) => {
  const store = useStore();
  // Turning on "no cost" erases a typed cost, and on a shared screen
  // that click can come from anyone. So the switch asks first.
  const [confirmingNoCost, setConfirmingNoCost] = useState(false);
  const confirmKeyRef = useRef(0);

  // Bills freeze at reconciliation, not at close — the server has
  // always allowed bill edits on a closed meal. Costs are often not
  // known until after the shopping, which is often after the close.
  // No meal loaded also freezes: rows must never be editable while
  // there is no meal to save them to.
  const frozen = !store.meal || store.meal.reconciled;

  return (
    <div className="confirm-bar-anchor">
      <div className="input-group">
        <select
          value={bill.resident_id}
          onChange={(e) => bill.setResident(e.target.value)}
          onBlur={() => store.flushPendingBillsSave()}
          style={styles.select}
          disabled={frozen}
          aria-label="Select meal cook"
        >
          <option value={""} key={-1}>
            ¯\_(ツ)_/¯
          </option>
          {cookChoices(store.residents, bill).map((resident) => (
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
            style={styles.select}
            className={bill.costPending ? "cost-pending" : ""}
            disabled={frozen}
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
      {confirmingNoCost && !isZeroAmountString(bill.amount) && (
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
