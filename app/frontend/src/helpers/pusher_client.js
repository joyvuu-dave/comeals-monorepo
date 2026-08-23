// How live updates work, end to end. This is the only place the whole
// protocol is written down; the server half is Community#trigger_pusher
// and Meal#trigger_pusher.
//
// 1. A Pusher message carries no data. It means "what you have for this
//    month is stale". The client always refetches; it never applies a
//    payload.
// 2. Before it broadcasts, the server deletes its own Rails cache entry
//    for the month (Community#invalidate_calendar_cache), so the refetch
//    cannot get a stale server copy.
// 3. Channels: community-<id>-calendar-<year>-<month> for a month (the
//    name is also the server cache key, on purpose), and meal-<id> for
//    one meal's page. The event name is always "update".
// 4. The client subscribes to the month on screen and refetches on
//    "update" (data_store_calendar.js loadMonth). It also subscribes to
//    the two neighbouring months and only evicts them from the client
//    caches, so the next navigation fetches fresh.
// 5. The browser that caused the change is excluded: the server passes
//    the client's socket_id, so a tap never triggers its own refetch.
// 6. Pusher does not replay messages missed while the socket was down,
//    so every reconnect and every browser "online" event refetches
//    (data_store_app.js handleReconnect).
// 7. With no VITE_PUSHER_KEY the client never connects and the app runs
//    without live updates; nothing else changes.
//
// This file is only the transport. It loads pusher-js outside the main
// bundle, so first paint does not wait for it (#44 item 1). The library
// is 60 KB and nothing on screen needs it.
//
// The rest of the app talks to `pusherClient`, which has the same shape
// as the small part of the Pusher API the app uses: subscribe,
// unsubscribe, and connection.bind. Calls made before the library
// arrives are queued and replayed in order, so callers never have to
// know or care that the client starts a moment after page load.

let real = null;
const queue = [];

function run(fn) {
  if (real) {
    fn(real);
  } else {
    queue.push(fn);
  }
}

// Channel wrappers, one per channel name. subscribe() must return an
// object right away, so callers get this wrapper; it forwards bind()
// to the real channel once that exists. Pusher's own subscribe() is
// safe to call twice with the same name — it returns the existing
// channel — so the wrapper's forwards never double-subscribe.
const channels = new Map();

export const pusherClient = {
  subscribe(name) {
    let channel = channels.get(name);
    if (!channel) {
      channel = {
        name: name,
        bind(event, callback) {
          run(function (pusher) {
            pusher.subscribe(name).bind(event, callback);
          });
        },
      };
      channels.set(name, channel);
      run(function (pusher) {
        pusher.subscribe(name);
      });
    }
    return channel;
  },

  unsubscribe(name) {
    channels.delete(name);
    run(function (pusher) {
      pusher.unsubscribe(name);
    });
  },

  connection: {
    bind(event, callback) {
      run(function (pusher) {
        pusher.connection.bind(event, callback);
      });
    },
    get socket_id() {
      return real ? real.connection.socket_id : null;
    },
  },
};

let started = false;

function connect(Pusher) {
  // Pusher public key + cluster from env vars (VITE_PUSHER_KEY,
  // VITE_PUSHER_CLUSTER). Local dev: the untracked .env file. CI has
  // no .env, so anything there that needs a key must set one itself.
  real = new Pusher(import.meta.env.VITE_PUSHER_KEY, {
    cluster: import.meta.env.VITE_PUSHER_CLUSTER,
    encrypted: true,
  });
  const pending = queue.splice(0);
  pending.forEach(function (fn) {
    fn(real);
  });
}

export function startPusher() {
  if (started) return;
  started = true;
  // No key, no connection. The staging app builds with a blank
  // VITE_PUSHER_KEY on purpose — it must not connect anywhere real,
  // and a placeholder key would spray console errors that fail the
  // smoke tests. Queued calls simply never replay; the app works
  // without live updates. Same graceful-absence pattern as bugsnag.js.
  if (!import.meta.env.VITE_PUSHER_KEY) return;
  // The tests stub window.Pusher (tests/helpers/setup.js) so no test
  // ever opens a real connection. The stub predates the lazy import
  // below; loading the real library anyway would bypass it, and did —
  // the CI-only failure that pinned this was pusher-js falling back
  // to an XHR that WebKit reports as a page error.
  if (window.Pusher) {
    connect(window.Pusher);
    return;
  }
  import("pusher-js").then(function (mod) {
    connect(mod.default);
  });
}
