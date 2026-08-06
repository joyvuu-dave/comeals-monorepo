import { useState } from "react";
import axios from "axios";
import handleAxiosError from "../../helpers/handle_axios_error";

// The delete flow every edit modal shares: Delete opens a ConfirmModal
// (the armMs guard stops an accidental double-tap, ADR 0006), a
// confirmed delete sends the request, and `onDeleted` runs on success
// to invalidate the month and close the form.
//
// Returns `requestDelete` for the header's Delete button and
// `confirmProps` to spread onto a <ConfirmModal />.
export default function useDeleteFlow({
  url,
  message,
  loadingAction,
  setLoadingAction,
  mountedRef,
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
      .delete(url)
      .then(function (response) {
        if (!mountedRef.current) return;
        setLoadingAction(null);
        if (response.status === 200) {
          onDeleted();
        }
      })
      .catch(function (error) {
        if (!mountedRef.current) return;
        setLoadingAction(null);
        handleAxiosError(error);
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
