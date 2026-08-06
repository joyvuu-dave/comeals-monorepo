import Icon from "../icon";

// The header row every calendar modal form starts with: the resource
// title, an optional Delete button (edit forms only), and the X that
// asks the discard gate to close (ADR 0006). The X is a real button so
// Enter and Space work without a hand-written key handler.
function ModalFormHeader({ title, onClose, onDelete, deleting, disabled }) {
  return (
    <div className="flex">
      <h2>{title}</h2>
      {onDelete && (
        <button
          onClick={onDelete}
          type="button"
          className={
            deleting
              ? "mar-l-md button-warning button-loader"
              : "mar-l-md button-warning"
          }
          disabled={disabled}
        >
          Delete
        </button>
      )}
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
