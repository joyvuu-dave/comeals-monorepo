// react-modal listens for Escape only on the dialog itself, so Escape
// closes a dialog only while focus is inside it. Focus moves to the
// page's <body> when the element that has it is removed, and in Chrome
// also when it is disabled. A form disables its buttons while its
// request is out, the ✕ of a message is removed when it is clicked, and
// the day picker is removed after a pick. After any of these, Escape
// did nothing (#148 for the calendar's forms, #152 for the password
// reset form). So when focus is on <body>, it goes back to the dialog
// itself, the element react-modal focuses when the dialog opens.
//
// A dialog uses it as its contentRef:
//
//   <Modal contentRef={watchDialogFocus} ...>
function refocusDialog(dialog: HTMLElement): void {
  if (document.activeElement === document.body) {
    dialog.focus({ preventScroll: true });
  }
}

// react-modal calls this with the dialog's element when the dialog
// opens, and with null when it closes. When the dialog closes, the
// element is removed, and the listener and the observer are freed with
// it, so they need no cleanup.
export default function watchDialogFocus(dialog: HTMLElement | null): void {
  if (!dialog) return;
  // Chrome sends focusout when the element that has focus is disabled
  // or removed. While focusout runs, <body> has focus even when focus is
  // moving to another element, so the check waits until the move is
  // done, as react-modal's own focus code does. This is a listener on
  // the element, not React's onBlur, because React drops the events a
  // browser sends while React is changing the page, and a removal sends
  // them then.
  dialog.addEventListener("focusout", function () {
    setTimeout(() => refocusDialog(dialog), 0);
  });
  // WebKit sends no event when the element that has focus is removed,
  // so every removal inside the dialog is checked too.
  new MutationObserver(() => refocusDialog(dialog)).observe(dialog, {
    childList: true,
    subtree: true,
  });
}
