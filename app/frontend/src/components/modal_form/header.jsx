import Icon from "../icon";

// The header row every calendar modal form starts with: the resource
// title and the X that asks the discard gate to close (ADR 0006). The
// X is a real button so Enter and Space work without a hand-written
// key handler. Delete is NOT here — it lives in ModalFormFooter, in
// the corner opposite Update, away from the X.
function ModalFormHeader({ title, onClose }) {
  return (
    <div className="flex modal-form-header">
      <h2>{title}</h2>
      <button
        type="button"
        className="close-button icon-button"
        onClick={onClose}
        aria-label="Close"
      >
        <Icon name="xmark" size="2x" />
      </button>
    </div>
  );
}

export default ModalFormHeader;
