import { Component } from "react";
import { notifyError } from "../../helpers/bugsnag";
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
  // The store, for the wait before a reload. index.jsx puts the
  // boundary inside the store's provider.
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
              // saved is sent and answered first, for a few seconds at
              // most (#150). If it was not saved, its message shows above
              // this page (index.jsx puts the messages outside the
              // boundary), and the page stays so the person can read it.
              // The next tap goes on.
              //
              // This page shows because something threw, and the store
              // may be what broke. Refresh is the only way off it, so a
              // wait that throws or fails is reported, and the page
              // reloads anyway.
              let waited;
              try {
                waited = this.context.finishBillsSaves();
              } catch (error) {
                waited = Promise.reject(error);
              }
              waited.then(
                function (mayReload) {
                  if (mayReload) window.location.reload();
                },
                function (error) {
                  notifyError(error);
                  window.location.reload();
                },
              );
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
