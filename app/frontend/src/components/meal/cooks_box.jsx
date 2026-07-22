import { useRef, useState } from "react";
import { inject, observer } from "mobx-react";
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

const BillEdit = inject("store")(
  observer(({ store, bill }) => {
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
            key={bill.id}
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
            {Array.from(store.residents.values())
              .filter((resident) => resident.can_cook === true)
              .map((resident) => (
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
              className={
                (bill.amountIsValid ? "" : "input-invalid") +
                (bill.costPending ? " cost-pending" : "")
              }
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
              key={`no_cost_switch_${bill.id}`}
              checked={bill ? bill.no_cost : false}
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
  }),
);

const BillShow = inject("store")(
  observer(({ bill }) => (
    <tr key={bill.id} hidden={!bill.resident}>
      <td>{bill.resident && bill.resident.name}</td>
      <td>{bill.costPending ? <em>pending</em> : `$${bill.amount}`}</td>
    </tr>
  )),
);

const Display = inject("store")(
  observer(({ store }) => (
    <table>
      <tbody>
        {Array.from(store.bills.values()).map((bill) => (
          <BillShow key={bill.id} bill={bill} />
        ))}
      </tbody>
    </table>
  )),
);

const Edit = inject("store")(
  observer(({ store }) => (
    <div>
      {Array.from(store.bills.values()).map((bill) => (
        <BillEdit key={bill.id} bill={bill} />
      ))}
    </div>
  )),
);

const CooksBox = inject("store")(
  observer(({ store }) => (
    <div className="offwhite button-border-radius" style={styles.main}>
      <div className="flex space-between title">
        <h2>Cooks</h2>
      </div>
      {store.editBillsMode ? <Edit /> : <Display />}
    </div>
  )),
);

export default CooksBox;
