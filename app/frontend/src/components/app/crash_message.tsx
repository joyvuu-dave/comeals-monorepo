import type { CSSProperties } from "react";

const styles: Record<"container" | "button", CSSProperties> = {
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

// The page that takes the place of the app after a crash. ErrorBoundary
// shows it in place of the pages, and OuterErrorBoundary in place of
// the whole app, so a person sees one crash page whichever part broke.
// It reads no store and no context: either may be what broke.
export default function CrashMessage({ onRefresh }: { onRefresh: () => void }) {
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
      <button style={styles.button} onClick={onRefresh}>
        Refresh
      </button>
    </div>
  );
}
