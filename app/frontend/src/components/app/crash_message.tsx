import {
  CRASH_ADVICE,
  CRASH_BUTTON_STYLE,
  CRASH_CONTAINER_STYLE,
  CRASH_EMAIL,
  CRASH_TITLE,
} from "../../helpers/crash_page";

// The page that takes the place of the app after a crash. ErrorBoundary
// shows it in place of the pages, and OuterErrorBoundary in place of
// the whole app, so a person sees one crash page whichever part broke.
// It reads no store and no context: either may be what broke. A crash
// before React draws anything gets the same page in plain HTML
// (helpers/boot_crash.ts).
export default function CrashMessage({ onRefresh }: { onRefresh: () => void }) {
  return (
    <div style={CRASH_CONTAINER_STYLE}>
      <h2>{CRASH_TITLE}</h2>
      <p>
        {CRASH_ADVICE} <a href={`mailto:${CRASH_EMAIL}`}>{CRASH_EMAIL}</a>.
      </p>
      <button style={CRASH_BUTTON_STYLE} onClick={onRefresh}>
        Refresh
      </button>
    </div>
  );
}
