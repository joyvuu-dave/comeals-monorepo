import { useEffect, useRef } from "react";
import { createPortal } from "react-dom";
import { observer } from "mobx-react-lite";
import toastStore from "../../stores/toast_store";
import "../../toast.css";

// A screen reader says an error at once. An element with role "alert"
// is said as soon as it comes onto the page.
var ALERT = { role: "alert", "aria-live": "assertive" };

// The class react-modal puts on <body> while any of its dialogs is
// open (its bodyOpenClassName, which no dialog in the app changes).
// Every dialog in the app is a react-modal: the calendar forms, the
// confirm dialog, the reset-password form and a meal's history.
var DIALOG_OPEN_CLASS = "ReactModal__Body--open";

// The words on the line under the stack, for the messages it hides.
function moreLabel(count) {
  return count === 1
    ? "Show 1 more message"
    : "Show " + count + " more messages";
}

// The stack of messages (#137), newest on top. The rules about which
// messages show and for how long are the toast store's
// (stores/toast_store.ts); this draws what it holds.
//
// Newest on top, so the stack reads the same way on a phone and on the
// shared screen: newest first, older messages under it, and the line
// for the oldest ones, when there are more than three, last.
//
// Screen readers. An error is its own alert. Every other message is said
// through one polite region that is always on the page, even with no
// messages: many screen readers say nothing about a live region that
// comes onto the page with its words already in it, only about words
// that go into a region they already know. The region holds the newest
// message that is not an error, as a new element each time, so the same
// words twice are said twice. The message on screen has no live role of
// its own, or a screen reader that does say it would say it twice.
//
// Where it is drawn (toast.css): at the bottom of the screen at every
// width, because the top of the screen holds the navigation. On a wide
// screen it sits at the bottom right. It is drawn under an open dialog,
// under the banners and under a yes/no question on the page, so it
// never covers a question, a form or a banner. A calendar form's own
// messages are not in the stack at all: they show inside the form
// (form_messages.tsx).
//
// A message under a dialog shows again when the dialog closes. So that
// a message with a timer does not close unseen while a dialog is open,
// the stack tells the store whether one is open, and the store runs no
// timers then (toast_store.ts).
//
// Drawn in document.body, outside #root. While a dialog is open,
// react-modal hides #root from screen readers with aria-hidden
// (Modal.setAppElement("#root")). The stack is outside #root, so
// aria-hidden does not hide a new error that comes while a dialog is
// open, such as the one that names a meal whose costs were not saved.
// react-modal also marks each dialog aria-modal="true". Chrome still
// shows the stack to screen readers then (seen in its accessibility
// tree). Whether VoiceOver in Safari says such an error has not been
// tried: Safari may hide everything outside a dialog marked that way.
//
// Room at the bottom of the page. The stack covers the end of the page,
// and an error stays until a person closes it. Without room, the last
// rows of a page, such as the last sign-up or the last week of the
// calendar, could sit under the stack with no way to scroll them above
// it. So while messages show, the page's root element holds the stack's
// height, and toast.css adds that much room under the page.
var ToastContainer = observer(function ToastContainer() {
  var shown = toastStore.shown;
  var hidden = toastStore.hiddenCount;
  var polite = toastStore.newestNotError;
  var boxRef = useRef(null);
  var showing = shown.length > 0;

  useEffect(
    function () {
      if (!showing) return;
      var root = document.documentElement;
      var box = boxRef.current;
      var observer = new ResizeObserver(function () {
        root.style.setProperty(
          "--message-stack-room",
          "calc(" + box.offsetHeight + "px + 2 * var(--space-4))",
        );
      });
      observer.observe(box);
      return function () {
        observer.disconnect();
        root.style.removeProperty("--message-stack-room");
      };
    },
    [showing],
  );

  useEffect(function () {
    var body = document.body;
    function look() {
      toastStore.setDialogOpen(body.classList.contains(DIALOG_OPEN_CLASS));
    }
    look();
    var watcher = new MutationObserver(look);
    watcher.observe(body, { attributes: true, attributeFilter: ["class"] });
    return function () {
      watcher.disconnect();
      // Once nothing watches, nothing can say a dialog closed, so the
      // timers must run.
      toastStore.setDialogOpen(false);
    };
  }, []);

  return createPortal(
    <>
      <div className="visually-hidden" role="status" aria-live="polite">
        {polite ? <span key={polite.id}>{polite.message}</span> : null}
      </div>
      {showing ? (
        <div ref={boxRef} className="toast-container">
          {shown.map(function (toast) {
            return (
              <div
                key={toast.id}
                className={"toast toast--" + toast.type}
                {...(toast.type === "error" ? ALERT : null)}
              >
                <span className="toast__message">{toast.message}</span>
                <button
                  className="toast__dismiss"
                  onClick={function () {
                    toastStore.remove(toast.id);
                  }}
                  aria-label="Dismiss"
                >
                  ✕
                </button>
              </div>
            );
          })}
          {hidden > 0 ? (
            <button
              type="button"
              className="button-secondary toast-more"
              onClick={function () {
                toastStore.showAll();
              }}
            >
              {moreLabel(hidden)}
            </button>
          ) : null}
        </div>
      ) : null}
    </>,
    document.body,
  );
});

export default ToastContainer;
