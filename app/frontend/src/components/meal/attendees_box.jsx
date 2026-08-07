import { observer } from "mobx-react-lite";
import { isAlive } from "mobx-state-tree";
import { useStore } from "../../helpers/store_context";
import Cow from "../../images/cow.png";
import Carrot from "../../images/carrot.png";
import GuestDropdown from "./guest_dropdown";

const styles = {
  main: {
    margin: "1em 0 1em 0",
    gridArea: "a5",
  },
  icon: {
    maxHeight: "1rem",
  },
  // Locked name cells keep a dimmed look without opacity: half-opacity
  // text blended below the WCAG AA contrast ratio (the Lighthouse
  // failure on reconciled meals). Plain cells dim by using an
  // AA-passing gray; attending (green) cells dim by draining the
  // color, which keeps their white text at AA because the gray keeps
  // the green's darkness.
  disabledPlain: {
    cursor: "not-allowed",
    color: "#666",
    pointerEvents: "none",
  },
  disabledAttending: {
    cursor: "not-allowed",
    filter: "grayscale(100%)",
    pointerEvents: "none",
  },
  monospace: {
    fontFamily: "Menlo, Consolas, 'DejaVu Sans Mono', monospace",
  },
};

const AttendeeComponent = observer(({ resident }) => {
  const store = useStore();
  // A row only makes sense against a loaded meal — every column
  // below reads meal state. No meal, no row.
  const meal = store.meal;
  if (!meal) return null;
  if (!isAlive(resident)) return null;
  const guests = resident.guests;
  const vegGuestsCount = guests.filter(
    (guest) => guest.vegetarian === true,
  ).length;
  const meatGuestsCount = guests.filter(
    (guest) => guest.vegetarian === false,
  ).length;

  return (
    <tr>
      <td
        onClick={() => resident.toggleAttending()}
        className={
          resident.attending
            ? "background-green text-white pointer background-transition"
            : "pointer background-transition"
        }
        style={Object.assign(
          {},
          ((resident.attending && !resident.canRemove) || meal.reconciled) &&
            (resident.attending
              ? styles.disabledAttending
              : styles.disabledPlain),
        )}
      >
        {resident.name}
      </td>
      <td>
        {vegGuestsCount > 0 && (
          <span className="badge badge-info mar-r-sm">
            {vegGuestsCount}
            <img src={Carrot} style={styles.icon} alt="carrot-icon" />
          </span>
        )}
        {meatGuestsCount > 0 && (
          <span className="badge badge-info">
            {meatGuestsCount}
            <img src={Cow} style={styles.icon} alt="cow-icon" />
          </span>
        )}
      </td>
      <td>
        <span className="switch">
          <input
            id={`late_switch_${resident.id}`}
            type="checkbox"
            className="switch"
            checked={resident.late}
            onChange={() => resident.toggleLate()}
            disabled={
              meal.reconciled ||
              (meal.closed && !resident.attending && meal.extras < 1)
            }
            aria-label={`Toggle Late for ${resident.name}`}
          />
          <label htmlFor={`late_switch_${resident.id}`} />
        </span>
      </td>
      <td>
        <span className="switch">
          <input
            id={`veg_switch_${resident.id}`}
            type="checkbox"
            className="switch"
            checked={resident.vegetarian}
            onChange={() => resident.toggleVeg()}
            disabled={
              meal.reconciled ||
              (meal.closed && resident.attending && !resident.canRemove) ||
              (meal.closed && !resident.attending && meal.extras < 1)
            }
            aria-label={`Toggle Veg for ${resident.name}`}
          />
          <label htmlFor={`veg_switch_${resident.id}`} />
        </span>
      </td>
      <td>
        <GuestDropdown
          resident={resident}
          reconciled={meal.reconciled}
          canAdd={store.canAdd}
        />
        <button
          className="dropdown-remove"
          aria-label={`Remove Guest of ${resident.name}`}
          style={styles.monospace}
          onClick={() => resident.removeGuest()}
          disabled={meal.reconciled || !resident.canRemoveGuest}
        />
      </td>
    </tr>
  );
});

const AttendeesBox = observer(() => {
  const store = useStore();
  return (
    <div style={styles.main}>
      <table className="background-white">
        <thead>
          <tr>
            <th className="background-white sticky-header">
              Name{" "}
              <span className="text-small text-italic text-secondary text-nowrap">
                (click to add)
              </span>
            </th>
            <th className="background-white sticky-header">Guests</th>
            <th className="background-white sticky-header">Late</th>
            <th className="background-white sticky-header">Veg</th>
            {/* The column of guest add/remove controls. It shows no
                visible title; the hidden text gives screen readers one. */}
            <th className="sticky-header">
              <span className="visually-hidden">Add or remove guests</span>
            </th>
          </tr>
        </thead>
        <tbody>
          {Array.from(store.residents.values()).map((resident) => (
            <AttendeeComponent key={resident.id} resident={resident} />
          ))}
        </tbody>
      </table>
    </div>
  );
});

export default AttendeesBox;
