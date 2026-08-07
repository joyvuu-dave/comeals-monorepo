import { observer } from "mobx-react-lite";
import { useStore } from "../../helpers/store_context";

const styles = {
  main: {
    padding: "1rem 0 0 1rem",
    backgroundColor: "white",
  },
  open: {
    visibility: "hidden",
  },
  closed: {},
  title: {
    textDecoration: "underline",
    fontSize: "1.25rem",
  },
};

const Extras = observer(() => {
  const store = useStore();
  return (
    <div style={styles.main}>
      {/* h3, not h5: the previous heading is the box's h2, and heading
          levels may only step down by one. fontSize keeps the h5 look. */}
      <h3 style={styles.title}>Extras</h3>
      <div
        style={store.meal && store.meal.closed ? styles.closed : styles.open}
      >
        {[0, 1, 2, 3, 4, 5, 6, 7, 8].map((val) => {
          return (
            <div key={val} className="pretty p-default p-round p-fill">
              <input
                key={val}
                type="checkbox"
                value={val}
                checked={store.meal ? store.meal.extras === val : false}
                onChange={(e) =>
                  store.meal && store.meal.setExtras(e.target.value)
                }
                disabled={
                  store.meal
                    ? store.meal.reconciled || store.meal.extrasPending
                    : false
                }
                aria-label={`Set Extras to ${val}`}
              />
              <div className="state p-success">
                <label>{val}</label>
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
});

export default Extras;
