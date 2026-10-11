import { useEffect, useRef, useState } from "react";
import { observer } from "mobx-react-lite";
import { DayPicker } from "react-day-picker";
import dayjs from "dayjs";
import utc from "dayjs/plugin/utc";
import { useStore } from "../../helpers/store_context";

dayjs.extend(utc);

// A day input with a pop-up month to pick from. Every day it takes and
// gives is the community's day, "YYYY-MM-DD". Its "today" is the
// community's today, not the device's (#129).
//
// react-day-picker works in the device's zone, so each day goes to it as
// noon on that day there, and comes back as the day those same fields
// name. Noon, not midnight: a device whose clock skips midnight on a day
// (Havana on Mar 8, 2026) has no midnight that day, and no clock change
// skips noon. A day is all that goes through the device's zone, never a
// time.
//
// Not the picker's timeZone prop: the picker then makes its Dates with
// TZDate (@date-fns/tz), a subclass of Date, and under Playwright's
// frozen clock (page.clock) a subclass of Date comes out as a plain
// Date. Every browser test that freezes the clock would then run the
// picker in the device's zone, so none of them could test it.

// What this reads in the DataStore.
interface PickerStore {
  // The community's day, which the store moves at the community's
  // midnight.
  readonly communityToday: string;
}

interface DayPickerInputProps {
  id: string;
  // The chosen day, or null before one is chosen.
  value?: string | null;
  placeholder?: string;
  // A day in the month the picker opens on when no day is chosen.
  defaultMonth?: string;
  // The last day that can be chosen.
  lastDay?: string;
  inputDisabled?: boolean;
  onDayChange?: (day: string) => void;
}

function noonOn(day: string): Date {
  const [year, month, date] = day.split("-").map(Number);
  return new Date(year, month - 1, date, 12);
}

function dayOf(date: Date): string {
  return dayjs(date).format("YYYY-MM-DD");
}

function DayPickerInputWrapper({
  id,
  value = null,
  placeholder = "",
  defaultMonth,
  lastDay,
  inputDisabled,
  onDayChange,
}: DayPickerInputProps) {
  const store: PickerStore = useStore();
  const [isOpen, setIsOpen] = useState(false);
  const wrapperRef = useRef<HTMLDivElement>(null);

  useEffect(function () {
    function handleClickOutside(event: MouseEvent) {
      if (
        wrapperRef.current &&
        !wrapperRef.current.contains(event.target as Node)
      ) {
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
  // deselected). The form keeps its day; the picker stays open.
  function handleDaySelect(date: Date | undefined) {
    if (!date) return;
    setIsOpen(false);
    onDayChange?.(dayOf(date));
  }

  // With no day chosen the input is empty; the placeholder attribute
  // shows the hint without looking like a chosen day.
  const shown = value === null ? "" : dayjs.utc(value).format("MM/DD/YYYY");

  // New forms pass the calendar's day as defaultMonth; edit forms open
  // the picker only once the record's day is in `value`. With neither,
  // the picker opens on today's month.
  const openOn = defaultMonth ?? value ?? store.communityToday;

  // Every form passes a last day by the time its picker can open; with
  // none, every day can be chosen.
  const tooLate = lastDay === undefined ? [] : [{ after: noonOn(lastDay) }];

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
        value={shown}
        onClick={handleInputClick}
        placeholder={placeholder}
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
            today={noonOn(store.communityToday)}
            selected={value === null ? undefined : noonOn(value)}
            onSelect={handleDaySelect}
            defaultMonth={noonOn(openOn)}
            disabled={tooLate}
          />
        </div>
      )}
    </div>
  );
}

export default observer(DayPickerInputWrapper);
