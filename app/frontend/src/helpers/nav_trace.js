// Dev-only navigation timing. Sprinkle `mark("label")` calls at key
// waypoints along the click → paint pipeline; call `report(label)` once
// the sequence has completed to log a breakdown to the console.
//
// Prod builds shim these to no-ops so there's zero overhead outside dev.
// See calendar/show.jsx and data_store.js for the current marks.
//
// In dev, each breakdown and Profiler commit is also POSTed to the Vite
// middleware at /__perf/log, which appends it as JSONL to log/perf.log.
// That way the session can be inspected from a file without copy/pasting
// from the browser console.

const ENABLED = import.meta.env.DEV;

// Marks recorded for the current in-flight navigation, in arrival order.
let trail = [];

export function mark(label, meta) {
  if (!ENABLED) return;
  const entry = { label, at: performance.now() };
  if (meta) entry.meta = meta;
  trail.push(entry);
}

// Schedule a "painted" mark on the second rAF after the caller — by that
// point the current commit has made it all the way to a pixel on screen
// (first rAF = style/layout/paint pipeline begins, second rAF = completed).
// Then print the breakdown and reset.
export function reportAfterPaint(label) {
  if (!ENABLED) return;
  const captured = trail;
  trail = [];
  requestAnimationFrame(() => {
    requestAnimationFrame(() => {
      captured.push({ label: "painted", at: performance.now() });
      printBreakdown(label, captured);
    });
  });
}

// React <Profiler> onRender callback. Logs commit phase + actualDuration
// so you can see how much each commit costs the subtree it wraps.
export function profileRender(id, phase, actualDuration) {
  if (!ENABLED) return;
  if (actualDuration < 2) return;
  // eslint-disable-next-line no-console
  console.log(`[profile ${id}] ${phase} ${actualDuration.toFixed(1)}ms`);
  postLog({
    kind: "profile",
    id,
    phase,
    actualDuration: +actualDuration.toFixed(1),
  });
}

function printBreakdown(label, entries) {
  if (entries.length < 2) return;
  const start = entries[0].at;
  const rows = [];
  for (let i = 1; i < entries.length; i++) {
    const prev = entries[i - 1];
    const cur = entries[i];
    const row = {
      leg: `${prev.label} → ${cur.label}`,
      ms: +(cur.at - prev.at).toFixed(1),
    };
    if (cur.meta) row.meta = cur.meta;
    rows.push(row);
  }
  const total = +(entries[entries.length - 1].at - start).toFixed(1);
  // eslint-disable-next-line no-console
  console.groupCollapsed(`[nav ${label}] total ${total}ms`);
  // eslint-disable-next-line no-console
  console.table(rows);
  // eslint-disable-next-line no-console
  console.groupEnd();
  postLog({ kind: "nav", label, total, rows });
}

// Direct one-off event log, independent of the navigation trail. Use for
// things like Pusher messages or store actions where we just want to know
// "this fired at time X".
export function logEvent(kind, extra) {
  if (!ENABLED) return;
  postLog({ kind, ...extra });
}

// Fire-and-forget POST to the Vite dev middleware. `keepalive` lets the
// request survive a rapid navigation. Errors are swallowed so the logger
// can never break the app.
function postLog(payload) {
  if (!ENABLED) return;
  try {
    fetch("/__perf/log", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ ts: Date.now(), ...payload }),
      keepalive: true,
    }).catch(() => {});
  } catch {
    // ignore
  }
}
