import { useEffect, useRef, useState } from "react";
import { inject, observer } from "mobx-react";
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

// The Yes button ignores clicks for its first moments on screen. The
// second tap of an accidental double-tap on the switch lands right after
// the bar appears — it must bounce off, not erase. A person who reads
// the question never notices the delay.
const ERASE_ARM_DELAY_MS = 400;

const BillEdit = inject("store")(
  observer(({ store, bill }) => {
    // Turning on "no cost" erases a typed cost, and on a shared screen
    // that click can come from anyone. So the switch asks first. Every
    // exit except a deliberate click on Yes — the No button, Escape, a
    // click anywhere else — leaves the cost alone.
    const [confirmingNoCost, setConfirmingNoCost] = useState(false);
    const openedAtRef = useRef(0);
    const confirmRef = useRef(null);
    const noButtonRef = useRef(null);

    // Focus lands on No, so Enter is a No too.
    useEffect(() => {
      if (confirmingNoCost && noButtonRef.current) {
        noButtonRef.current.focus();
      }
    }, [confirmingNoCost]);

    useEffect(() => {
      if (!confirmingNoCost) return undefined;
      const onMouseDown = (e) => {
        if (confirmRef.current && !confirmRef.current.contains(e.target)) {
          setConfirmingNoCost(false);
        }
      };
      const onKeyDown = (e) => {
        if (e.key === "Escape") {
          setConfirmingNoCost(false);
        }
      };
      document.addEventListener("mousedown", onMouseDown);
      document.addEventListener("keydown", onKeyDown);
      return () => {
        document.removeEventListener("mousedown", onMouseDown);
        document.removeEventListener("keydown", onKeyDown);
      };
    }, [confirmingNoCost]);

    const confirmErase = () => {
      if (Date.now() - openedAtRef.current < ERASE_ARM_DELAY_MS) return;
      setConfirmingNoCost(false);
      bill.toggleNoCost();
    };

    return (
      <>
        <div className="input-group">
          <select
            key={bill.id}
            value={bill.resident_id}
            onChange={(e) => bill.setResident(e.target.value)}
            onBlur={() => store.flushPendingBillsSave()}
            style={styles.select}
            disabled={store.meal.closed || store.meal.reconciled}
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
              className={bill.amountIsValid ? "" : "input-invalid"}
              disabled={store.meal.closed || store.meal.reconciled}
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
                  openedAtRef.current = Date.now();
                  setConfirmingNoCost(true);
                  return;
                }
                bill.toggleNoCost();
              }}
              onBlur={() => store.flushPendingBillsSave()}
              disabled={
                store.meal.closed ||
                store.meal.reconciled ||
                !bill.resident_id
              }
              aria-label={`No cost button for ${bill.id}`}
            />
            <label htmlFor={`no_cost_switch-${bill.id}`} />
          </span>
        </div>
        {confirmingNoCost && !isZeroAmountString(bill.amount) && (
          <div
            className="no-cost-confirm"
            ref={confirmRef}
            role="alertdialog"
            aria-label={`Erase ${bill.resident.name}'s $${toDisplayAmountString(bill.amount)}?`}
          >
            <span className="no-cost-confirm-question">
              Erase{" "}
              <strong>
                {bill.resident.name}&rsquo;s ${toDisplayAmountString(bill.amount)}
              </strong>
              ?
            </span>
            {/* Yes sits away from the switch; No sits right under it, so
                a stray second tap lands on No. */}
            <span className="no-cost-confirm-buttons">
              <button
                type="button"
                className="button button-danger"
                onClick={confirmErase}
              >
                Yes
              </button>
              <button
                type="button"
                className="button"
                ref={noButtonRef}
                onClick={() => setConfirmingNoCost(false)}
              >
                No
              </button>
            </span>
          </div>
        )}
      </>
    );
  }),
);

const BillShow = inject("store")(
  observer(({ bill }) => (
    <tr key={bill.id} hidden={!bill.resident}>
      <td>{bill.resident && bill.resident.name}</td>
      <td>${bill.amount}</td>
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
