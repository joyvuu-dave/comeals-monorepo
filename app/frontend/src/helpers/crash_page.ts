// What the crash page says and how it looks, for its two forms: the
// React component (components/app/crash_message.tsx), and the plain HTML
// the start-up draws when it crashes before React draws anything
// (helpers/boot_crash.ts). One place, so the two never say different
// things.

export const CRASH_TITLE = "Something went wrong with Comeals.";
// The advice, followed by a link to the email address and a period.
export const CRASH_ADVICE =
  "Try refreshing the page. If that doesn't fix it, email David at";
export const CRASH_EMAIL = "david.paul.riddle@gmail.com";

// Plain strings, so both a React style prop and an element's style take
// them.
export const CRASH_CONTAINER_STYLE = {
  display: "flex",
  flexDirection: "column",
  alignItems: "center",
  justifyContent: "center",
  minHeight: "60vh",
  padding: "2rem",
  textAlign: "center",
} as const;

export const CRASH_BUTTON_STYLE = {
  marginTop: "1rem",
  padding: "0.75rem 2rem",
  fontSize: "1rem",
  lineHeight: "1",
  backgroundColor: "var(--gray-13)",
  color: "var(--white)",
  border: "none",
  borderRadius: "var(--radius)",
  cursor: "pointer",
} as const;
