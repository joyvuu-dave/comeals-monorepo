import { inject, observer } from "mobx-react";

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
  observer(({ store, bill }) => (
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
          onBlur={() => store.flushPendingBillsSave()}
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
          onChange={() => bill.toggleNoCost()}
          onBlur={() => store.flushPendingBillsSave()}
          disabled={
            store.meal.closed ||
            store.meal.reconciled ||
            !bill.resident_id ||
            bill.amount > 0
          }
          aria-label={`No cost button for ${bill.id}`}
        />
        <label htmlFor={`no_cost_switch-${bill.id}`} />
      </span>
    </div>
  )),
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
