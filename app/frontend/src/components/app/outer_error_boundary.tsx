import { Component } from "react";
import type { ErrorInfo, ReactNode } from "react";

import { notifyError } from "../../helpers/bugsnag";
import { waitAfterCrash } from "../../helpers/crash_reload_wait";
import { crashPageLoader } from "../../helpers/load_after_crash";
import CrashMessage from "./crash_message";

interface Props {
  children: ReactNode;
  // Sends the cost saves that wait, before a page load (the store's
  // finishBillsSaves). The store may be what broke, so this may throw,
  // fail, or never answer.
  sendWaitingSaves: () => Promise<unknown>;
}

interface State {
  crashed: boolean;
}

// Around the whole app (index.jsx). ErrorBoundary is around the pages
// only. A render error anywhere outside it (the message stack, the
// banners, the idle timer) used to take the whole page away, the idle
// timer with it, so a shared screen stayed blank until someone came and
// reloaded it. This shows the crash page in place of the app, reports
// the error, and loads "/" by itself after a wait.
//
// It uses no store and no context, since either may be what broke. Its
// timer is a plain setTimeout kept on the instance, not React state. The
// wait grows if the page keeps crashing (helpers/crash_reload_wait.ts).
export default class OuterErrorBoundary extends Component<Props, State> {
  state: State = { crashed: false };

  // Set at the first error, so the page is reported once and gets one
  // timer.
  private noted = false;
  private reloadTimer: ReturnType<typeof setTimeout> | undefined;
  // Sends the cost saves that wait, then loads the page, once
  // (helpers/load_after_crash.ts). Nothing stops the load: the message
  // that a save was not saved went with the crash, so there is no
  // message on screen to keep the page for.
  private loadAfterSaves = crashPageLoader(() => this.props.sendWaitingSaves());

  static getDerivedStateFromError(): State {
    return { crashed: true };
  }

  componentDidCatch(error: Error, errorInfo: ErrorInfo) {
    if (this.noted) return;
    this.noted = true;
    console.error("OuterErrorBoundary caught:", error, errorInfo);
    // React hands a render error here, not to window.onerror, so
    // Bugsnag's own handlers never see it.
    notifyError(error, { componentStack: errorInfo.componentStack });
    this.reloadTimer = setTimeout(() => {
      this.loadAfterSaves(function () {
        window.location.assign("/");
      });
    }, waitAfterCrash());
  }

  componentWillUnmount() {
    clearTimeout(this.reloadTimer);
  }

  render() {
    if (this.state.crashed) {
      return (
        <CrashMessage
          onRefresh={() => {
            this.loadAfterSaves(function () {
              window.location.reload();
            });
          }}
        />
      );
    }
    return this.props.children;
  }
}
