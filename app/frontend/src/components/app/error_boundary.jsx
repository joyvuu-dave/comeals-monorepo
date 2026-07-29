import { Component } from "react";
import { notifyError } from "../../helpers/bugsnag";

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
    backgroundColor: "#444",
    color: "#fff",
    border: "none",
    borderRadius: "4px",
    cursor: "pointer",
  },
};

class ErrorBoundary extends Component {
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
            onClick={function () {
              window.location.reload();
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
