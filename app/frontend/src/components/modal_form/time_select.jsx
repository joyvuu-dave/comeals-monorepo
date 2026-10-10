import { generateTimes } from "../../helpers/helpers";

// "07:00" as the menu writes it: "7:00 AM".
function display(time) {
  var [hours, minutes] = time.split(":").map(Number);
  var ending = hours < 12 ? "AM" : "PM";
  var hour = hours % 12 === 0 ? 12 : hours % 12;
  return `${hour}:${minutes.toString().padStart(2, "0")} ${ending}`;
}

// The menu's choices: 15-minute steps from 8:00 AM to 10:00 PM, and
// `storedTime` too when it is not one of them, in its place by time.
// "HH:MM" strings sort by time.
function choices(storedTime) {
  var times = generateTimes();
  if (!storedTime || times.some((time) => time.value === storedTime)) {
    return times;
  }
  var stored = { value: storedTime, display: display(storedTime) };
  var before = times.filter((time) => time.value < storedTime);
  var after = times.filter((time) => time.value > storedTime);
  return [...before, stored, ...after];
}

// A labeled time dropdown (15-minute slots, 8am-10pm). The leading
// empty option keeps the controlled value="" matching an option.
//
// An edit form passes the entry's stored time as `storedTime`. A time
// made in admin can be any minute, such as 7:00 AM. A menu without it
// showed the empty choice while the form held that time and sent it
// (#147), so it is added as one more choice. It is the stored time, not
// the value, so it stays on the menu after the person picks another
// time, and they can pick it again.
function TimeSelect({ id, label, value, onChange, disabled, storedTime }) {
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
        {choices(storedTime).map((time) => (
          <option key={time.value} value={time.value}>
            {time.display}
          </option>
        ))}
      </select>
    </>
  );
}

export default TimeSelect;
