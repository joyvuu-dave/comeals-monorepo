// The action row every calendar edit form ends with: Update on the
// left, Delete alone on the far right. Opposite corners, so a click
// aimed at one cannot land on the other — and Delete sits as far as
// possible from the header's X, instead of next to it (the old
// layout, where a slip while closing could reach the destructive
// button). Delete still confirms through useDeleteFlow.
function ModalFormFooter({ submitting, deleting, onDelete, disabled }) {
  return (
    <div className="flex space-between">
      <button
        type="submit"
        className={submitting ? "button-dark button-loader" : "button-dark"}
        disabled={disabled}
      >
        Update
      </button>
      <button
        type="button"
        onClick={onDelete}
        className={deleting ? "button-warning button-loader" : "button-warning"}
        disabled={disabled}
      >
        Delete
      </button>
    </div>
  );
}

export default ModalFormFooter;
