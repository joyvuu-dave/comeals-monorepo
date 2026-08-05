import { useEffect, useRef } from "react";
import Modal from "react-modal";

Modal.setAppElement("#root");

// The yes/no dialog for actions that deserve a pause before they
// happen. Follows the same popup contract as confirm_bar.jsx: the
// question does the talking, the safe answer (onCancel) takes focus so
// Enter is a no, and Escape or a click outside the dialog is also a
// no.
//
// armMs guards the confirm button: clicks bounce off until the dialog
// has been open that long, so the second tap of an accidental
// double-tap cannot confirm. Anyone who reads the question never
// notices the delay.
function ConfirmModal({
  isOpen,
  message,
  onCancel,
  onConfirm,
  cancelLabel,
  confirmLabel,
  armMs = 0,
}) {
  const openedAtRef = useRef(0);

  // Who had focus when the dialog opened — restored on close so a
  // keyboard user lands back where they were (react-modal's own
  // focus return is coupled to shouldFocusAfterRender, which is off
  // below). Restoring to an element the close just unmounted is a
  // harmless no-op.
  const restoreFocusRef = useRef(null);

  useEffect(
    function () {
      if (isOpen) {
        openedAtRef.current = Date.now();
        restoreFocusRef.current = document.activeElement;
      } else if (restoreFocusRef.current) {
        if (typeof restoreFocusRef.current.focus === "function") {
          restoreFocusRef.current.focus();
        }
        restoreFocusRef.current = null;
      }
    },
    [isOpen],
  );

  function handleConfirmClick() {
    if (Date.now() - openedAtRef.current < armMs) return;
    onConfirm();
  }

  return (
    <Modal
      isOpen={isOpen}
      onRequestClose={onCancel}
      // react-modal would focus the dialog itself; the autoFocus on
      // the cancel button places it on the safe answer instead, so
      // Enter is a no. The button mounts only when the dialog opens,
      // so autoFocus fires on every open.
      shouldFocusAfterRender={false}
      contentLabel="Confirm"
      style={{
        overlay: { zIndex: 10001 },
        content: {
          top: "50%",
          left: "50%",
          right: "auto",
          bottom: "auto",
          marginRight: "-50%",
          transform: "translate(-50%, -50%)",
          // 24rem, but never wider than the screen minus a margin —
          // 24rem alone is 384px, wider than the smallest phones.
          maxWidth: "min(24rem, calc(100vw - 2rem))",
          padding: "1.5rem",
        },
      }}
    >
      <p style={{ marginTop: 0, marginBottom: "1.5rem", fontSize: "1rem" }}>
        {message}
      </p>
      <div
        style={{
          display: "flex",
          gap: "0.75rem",
          justifyContent: "flex-end",
        }}
      >
        <button
          type="button"
          className="button-light"
          autoFocus
          onClick={onCancel}
        >
          {cancelLabel}
        </button>
        <button
          type="button"
          className="button-warning"
          onClick={handleConfirmClick}
        >
          {confirmLabel}
        </button>
      </div>
    </Modal>
  );
}

export default ConfirmModal;
