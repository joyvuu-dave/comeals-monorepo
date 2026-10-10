import { Component } from "react";
import { notifyError } from "../../helpers/bugsnag";
import { loadAfterBillsSaves } from "../../helpers/load_after_bills_saves";
import { StoreContext } from "../../helpers/store_context";

var styles = {
  container: {
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    justifyContent: "center",
    minHeight: "60vh",
    padding: "2rem",
    textAlign: "center",
  },
  button: {
    marginTop: "1rem",
    padding: "0.75rem 2rem",
    fontSize: "1rem",
    lineHeight: "1",
    backgroundColor: "var(--gray-13)",
    color: "var(--white)",
    border: "none",
    borderRadius: "var(--radius)",
    cursor: "pointer",
  },
};

class ErrorBoundary extends Component {
  // The store, for the note that the page crashed and for the wait
  // before a reload. index.jsx puts the boundary inside the store's
  // provider.
  static contextType = StoreContext;

  constructor(props) {
    super(props);
    this.state = { hasError: false };
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
    // The idle timer reads the note and loads today's calendar, because
    // this page stays when the address changes (back_to_today.tsx). The
    // store may be what broke, and an error thrown here would take this
    // page away too. So a note that fails is skipped: the page still
    // shows Refresh, and only the timer's load is lost.
    try {
      this.context.markPageCrashed();
    } catch {
      // Skipped, as said above.
    }
  }

  render() {
    if (this.state.hasError) {
      return (
        <div style={styles.container}>
          <h2>Something went wrong with Comeals.</h2>
          <p>
            Try refreshing the page. If that doesn't fix it, email David at{" "}
            <a href="mailto:david.paul.riddle@gmail.com">
              david.paul.riddle@gmail.com
            </a>
            .
          </p>
          <button
            style={styles.button}
            onClick={() => {
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
          >
            Refresh
          </button>
        </div>
      );
    }

    return this.props.children;
  }
}

export default ErrorBoundary;
