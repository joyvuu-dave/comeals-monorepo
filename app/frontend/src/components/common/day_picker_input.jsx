import { useEffect, useRef, useState } from "react";
import { DayPicker } from "react-day-picker";
import dayjs from "dayjs";

function DayPickerInputWrapper({
  id,
  value,
  placeholder,
  defaultMonth,
  disabledDays,
  inputDisabled,
  onDayChange,
}) {
  const [isOpen, setIsOpen] = useState(false);
  const wrapperRef = useRef(null);

  useEffect(function () {
    function handleClickOutside(event) {
      if (wrapperRef.current && !wrapperRef.current.contains(event.target)) {
        setIsOpen(false);
      }
    }

    document.addEventListener("mousedown", handleClickOutside);
    return function () {
      document.removeEventListener("mousedown", handleClickOutside);
    };
  }, []);

  // A disabled input gets no click events, so the disabled attribute
  // on the input is the whole guard.
  function handleInputClick() {
    setIsOpen(true);
  }

  // Clicking the selected day again hands over undefined (the day was
  // deselected). The form keeps its date; the picker stays open.
  function handleDaySelect(date) {
    if (!date) return;
    setIsOpen(false);
    onDayChange(date);
  }

  function formatValue() {
    if (!value) return placeholder || "";
    return dayjs(value).format("MM/DD/YYYY");
  }

  return (
    <div
      ref={wrapperRef}
      style={{ display: "inline-block", position: "relative" }}
    >
      <input
        id={id}
        type="text"
        readOnly
        disabled={inputDisabled}
        value={formatValue()}
        onClick={handleInputClick}
        placeholder={placeholder || ""}
      />
      {isOpen && (
        <div
          style={{
            position: "absolute",
            left: 0,
            zIndex: 1,
            background: "var(--white)",
            boxShadow: "0 2px 5px rgba(0,0,0,0.15)",
          }}
        >
          <DayPicker
            mode="single"
            selected={value ? dayjs(value).toDate() : undefined}
            onSelect={handleDaySelect}
            // New forms pass the calendar's month; edit forms open the
            // picker only once the record's day is in `value`.
            defaultMonth={defaultMonth || dayjs(value).toDate()}
            disabled={disabledDays}
          />
        </div>
      )}
    </div>
  );
}

export default DayPickerInputWrapper;
