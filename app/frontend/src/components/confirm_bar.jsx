import { useEffect, useRef } from "react";

// A yes/no bar for actions that deserve a pause before they happen.
// The popup contract on this shared screen: the question does the
// talking, and the only answers are Yes and No. No is the filled
// button at the far right — under the control that was just tapped, so
// a stray second tap lands on No — and it takes focus, so Enter is a
// No. Escape and a click anywhere else are also a No. Only a
// deliberate click on the red Yes proceeds.
//
// armMs guards a destructive Yes: clicks bounce off until the bar has
// been on screen that long, so the second tap of an accidental
// double-tap cannot confirm. Anyone who reads the question never
// notices the delay.
const ConfirmBar = ({
  question,
  ariaLabel,
  onYes,
  onDismiss,
  armMs = 0,
  className = "",
}) => {
  const openedAtRef = useRef(Date.now());
  const barRef = useRef(null);
  const noButtonRef = useRef(null);

  useEffect(() => {
    if (noButtonRef.current) {
      noButtonRef.current.focus();
    }
  }, []);

  useEffect(() => {
    const onMouseDown = (e) => {
      if (barRef.current && !barRef.current.contains(e.target)) {
        onDismiss();
      }
    };
    const onKeyDown = (e) => {
      if (e.key === "Escape") {
        onDismiss();
      }
    };
    document.addEventListener("mousedown", onMouseDown);
    document.addEventListener("keydown", onKeyDown);
    return () => {
      document.removeEventListener("mousedown", onMouseDown);
      document.removeEventListener("keydown", onKeyDown);
    };
  }, [onDismiss]);

  return (
    <div
      className={`confirm-bar ${className}`.trim()}
      ref={barRef}
      role="alertdialog"
      aria-label={ariaLabel}
    >
      <span className="confirm-bar-question">{question}</span>
      <span className="confirm-bar-buttons">
        <button
          type="button"
          className="button button-danger"
          onClick={() => {
            if (Date.now() - openedAtRef.current < armMs) return;
            onYes();
          }}
        >
          Yes
        </button>
        <button
          type="button"
          className="button"
          ref={noButtonRef}
          onClick={onDismiss}
        >
          No
        </button>
      </span>
    </div>
  );
};

export default ConfirmBar;
