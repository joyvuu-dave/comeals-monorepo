import { generateTimes } from "../../helpers/helpers";

// A labeled time dropdown (15-minute slots, 8am-10pm). The leading
// empty option keeps the controlled value="" matching an option.
function TimeSelect({ id, label, value, onChange, disabled }) {
  return (
    <>
      <label htmlFor={id}>{label}</label>
      <select
        id={id}
        value={value}
        onChange={(e) => onChange(e.target.value)}
        disabled={disabled}
      >
        <option />
        {generateTimes().map((time) => (
          <option key={time.value} value={time.value}>
            {time.display}
          </option>
        ))}
      </select>
    </>
  );
}

export default TimeSelect;
