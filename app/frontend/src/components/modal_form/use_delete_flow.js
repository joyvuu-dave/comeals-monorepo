import { useState } from "react";
import axios from "axios";
import { requestKeyHeaders } from "../../helpers/use_request_key";

// The delete flow every edit modal shares: Delete opens a ConfirmModal
// (the armMs guard stops an accidental double-tap, ADR 0006), a
// confirmed delete sends the request, and `onDeleted` runs on success
// to invalidate the month and close the form. A failed delete shows
// through `showError`, the form's own (use_form_messages.ts), so the
// message goes when the form closes.
//
// `requestKey` is the delete's Idempotency-Key (ADR 0015). The caller
// builds it from the record's id: a record is deleted once and its id is
// never used again, so every send of this delete is the same request.
// A delete whose answer was lost and is confirmed again is answered as
// done, not with "doesn't exist".
//
// Returns `requestDelete` for the header's Delete button and
// `confirmProps` to spread onto a <ConfirmModal />.
export default function useDeleteFlow({
  url,
  requestKey,
  message,
  loadingAction,
  setLoadingAction,
  mountedRef,
  showError,
  onDeleted,
}) {
  const [confirmOpen, setConfirmOpen] = useState(false);

  function requestDelete() {
    if (loadingAction) return;
    setConfirmOpen(true);
  }

  function handleConfirm() {
    setConfirmOpen(false);
    setLoadingAction("delete");
    axios
      .delete(url, { headers: requestKeyHeaders(requestKey) })
      .then(function () {
        if (!mountedRef.current) return;
        setLoadingAction(null);
        onDeleted();
      })
      .catch(function (error) {
        if (!mountedRef.current) return;
        setLoadingAction(null);
        showError(error);
      });
  }

  function handleCancel() {
    setConfirmOpen(false);
  }

  return {
    requestDelete,
    confirmProps: {
      isOpen: confirmOpen,
      message: message,
      cancelLabel: "Cancel",
      confirmLabel: "Delete",
      armMs: 400,
      onConfirm: handleConfirm,
      onCancel: handleCancel,
    },
  };
}
