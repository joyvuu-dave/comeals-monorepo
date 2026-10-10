import { Component } from "react";
import { notifyError } from "../../helpers/bugsnag";
import { waitAfterCrash } from "../../helpers/crash_reload_wait";
import { loadAfterBillsSaves } from "../../helpers/load_after_bills_saves";
import { crashPageLoader } from "../../helpers/load_after_crash";
import { StoreContext } from "../../helpers/store_context";
import CrashMessage from "./crash_message";

class ErrorBoundary extends Component {
  // The store, for the note that the page crashed and for the wait
  // before a reload. index.jsx puts the boundary inside the store's
  // provider.
  static contextType = StoreContext;

  constructor(props) {
    super(props);
    this.state = { hasError: false };
    // Set at the first error. Two parts of the page can fail in one go,
    // and that is one crash: counted twice, the wait would grow as if
    // the page had crashed twice.
    this.noted = false;
    // This page's own timer, only when the store could not take the
    // note (componentDidCatch).
    this.reloadTimer = undefined;
    // Sends the cost saves that wait, then loads the page, once
    // (helpers/load_after_crash.ts).
    this.loadAfterSaves = crashPageLoader(() =>
      this.context.finishBillsSaves(),
    );
  }

  static getDerivedStateFromError() {
    return { hasError: true };
  }

  componentDidCatch(error, errorInfo) {
    console.error("ErrorBoundary caught:", error, errorInfo);
    // React catches a render error and hands it here rather than letting it
    // reach window.onerror, so Bugsnag's automatic handlers never see it.
    // Without this call, the one error that replaces the whole screen is
    // the one error that gets reported nowhere.
    notifyError(error, {
      componentStack: errorInfo && errorInfo.componentStack,
    });
    if (this.noted) return;
    this.noted = true;
    // The idle timer reads the note and loads today's calendar, because
    // this page stays when the address changes (back_to_today.tsx). The
    // note carries how long it waits, which grows when the page keeps
    // crashing (helpers/crash_reload_wait.ts).
    const wait = waitAfterCrash();
    try {
      this.context.markPageCrashed(wait);
    } catch {
      // The store may be what broke, and an error thrown here would take
      // this page away too. Without the note, the idle timer never
      // learns of the crash, and this page would stay for good. So this
      // page starts its own plain timer with the same wait, the way
      // OuterErrorBoundary does, and loads "/". With the note, there is
      // no timer here: the idle timer loads the page, and a second
      // timer would load it twice.
      this.reloadTimer = setTimeout(() => {
        this.loadAfterSaves(function () {
          window.location.assign("/");
        });
      }, wait);
    }
  }

  componentWillUnmount() {
    clearTimeout(this.reloadTimer);
  }

  render() {
    if (this.state.hasError) {
      return (
        <CrashMessage
          onRefresh={() => {
            // A reload ends every request on its way, so a cost being
            // saved is sent and answered first (#150). If it was not
            // saved, its message shows above this page (index.jsx
            // puts the messages outside the boundary), and the page
            // stays so the person can read it. The next tap goes on.
            // This page shows because something threw, and the store
            // may be what broke, so a wait that fails still reloads.
            loadAfterBillsSaves(this.context, function () {
              window.location.reload();
            });
          }}
        />
      );
    }

    return this.props.children;
  }
}

export default ErrorBoundary;
