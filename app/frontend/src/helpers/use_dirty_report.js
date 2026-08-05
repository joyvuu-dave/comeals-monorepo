import { useEffect } from "react";

// Reports whether a modal form holds unsaved changes. The calendar
// page owns the close gate (see calendar/show.jsx): a close request on
// a dirty form opens the "Discard your changes?" dialog instead of
// closing (ADR 0006).
//
// Forms compute `isDirty` by comparing their fields to the values they
// started with, so a change that is typed and then undone counts as
// clean. The unmount cleanup reports clean: a closed form has nothing
// left to lose, and a stale flag must not block the next modal.
export default function useDirtyReport(setDirty, isDirty) {
  useEffect(
    function () {
      setDirty(isDirty);
    },
    [setDirty, isDirty],
  );

  useEffect(
    function () {
      return function () {
        setDirty(false);
      };
    },
    [setDirty],
  );
}
