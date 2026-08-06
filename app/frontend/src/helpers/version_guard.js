// The stale-response guard the stores use everywhere a response can
// arrive after the state it answers is gone: bump() when the state
// moves (an edit, a new fetch, a navigation), capture current() when a
// request goes out, and apply the response only if isCurrent(token)
// still holds. One shared shape so every use site reads the same way;
// the differences that matter (what bumps, what checks) stay visible
// at the call sites.
export default function createVersionGuard() {
  let version = 0;
  return {
    // The state moved. Returns the new version, so a caller that bumps
    // and captures in one step (a new fetch) can keep the return value.
    bump() {
      version += 1;
      return version;
    },
    // The version right now, captured when a request goes out.
    current() {
      return version;
    },
    // True when nothing has bumped since the token was captured.
    isCurrent(token) {
      return version === token;
    },
  };
}
