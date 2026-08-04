import { useEffect, useRef } from "react";
import { observer } from "mobx-react";
import toastStore from "../../stores/toast_store";
import "../../toast.css";

var AUTO_DISMISS_MS = {
  success: 5000,
  info: 5000,
  warning: 8000,
  error: 15000,
};

var ToastContainer = observer(function ToastContainer() {
  var timersRef = useRef({});

  // No dependency array: run after every render, like the class's
  // componentDidMount + componentDidUpdate pair. Starting a timer twice
  // is prevented by the timers map, not by the effect's schedule.
  useEffect(function () {
    var timers = timersRef.current;
    toastStore.toasts.forEach(function (toast) {
      if (!timers[toast.id]) {
        var delay = AUTO_DISMISS_MS[toast.type] || 5000;
        timers[toast.id] = setTimeout(function () {
          toastStore.removeToast(toast.id);
          delete timers[toast.id];
        }, delay);
      }
    });
  });

  // Unmount only: clear every pending timer.
  useEffect(function () {
    var timers = timersRef.current;
    return function () {
      Object.keys(timers).forEach(function (id) {
        clearTimeout(timers[id]);
      });
    };
  }, []);

  function handleDismiss(id) {
    var timers = timersRef.current;
    if (timers[id]) {
      clearTimeout(timers[id]);
      delete timers[id];
    }
    toastStore.removeToast(id);
  }

  if (toastStore.toasts.length === 0) {
    return null;
  }

  return (
    <div className="toast-container" aria-relevant="additions">
      {toastStore.toasts.map(function (toast) {
        return (
          <div
            key={toast.id}
            className={"toast toast--" + toast.type}
            role="alert"
            aria-live="assertive"
          >
            <span className="toast__message">{toast.message}</span>
            <button
              className="toast__dismiss"
              onClick={function () {
                handleDismiss(toast.id);
              }}
              aria-label="Dismiss"
            >
              ✕
            </button>
          </div>
        );
      })}
    </div>
  );
});

export default ToastContainer;
