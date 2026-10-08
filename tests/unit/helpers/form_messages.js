import toastStore from "../../../app/frontend/src/stores/toast_store";

// Where a calendar form's messages show: the words inside the form, top
// to bottom (form_messages.tsx), and the words in the stack of messages
// (toast_container.jsx). A form's own messages show inside it, and never
// in the stack (#137).
export function messagesShown() {
  return {
    form: Array.from(document.querySelectorAll(".form-message__text")).map(
      (node) => node.textContent,
    ),
    stack: toastStore.toasts.map((toast) => toast.message),
  };
}
