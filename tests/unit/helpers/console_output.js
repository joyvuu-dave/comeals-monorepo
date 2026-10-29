// The console output a test says it expects. render_setup.js fails a
// test that writes to console.error or console.warn unless the message
// matches one of these (#249).
//
//   expectConsole("warn", /This browser blocks localStorage/);
//
// Each expectation must be met at least once, so one that no longer
// matches anything fails the test too, and does not stay behind.
let expected = [];

export function expectConsole(method, pattern) {
  expected.push({ method, pattern, seen: false });
}

// A message meets the first expectation it matches that is not met yet,
// so a pattern declared twice (in a beforeEach and in the test) needs
// the message twice. Once every match is met, more of the same message
// is still expected.
export function isExpected(method, message) {
  const matches = expected.filter(
    (item) => item.method === method && item.pattern.test(message),
  );
  if (matches.length === 0) return false;
  (matches.find((item) => !item.seen) || matches[0]).seen = true;
  return true;
}

export function expectedNotSeen() {
  return expected
    .filter((item) => !item.seen)
    .map((item) => `console.${item.method}: ${item.pattern}`);
}

export function clearExpected() {
  expected = [];
}
