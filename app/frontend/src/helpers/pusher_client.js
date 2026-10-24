// How live updates work, end to end. This is the only place the whole
// protocol is written down; the server half is app/services/live_update.rb.
//
// 1. A Pusher message carries no data. It means "what you have for this
//    is stale". The client always refetches; it never applies a payload.
// 2. The server pushes after the write commits, from the models — so
//    every writer pushes, not only the API. Before it pushes it deletes
//    its own Rails cache entry for the month, and the entry is stored
//    under a version read from the rows, so a refetch can never get a
//    stale server copy — not even one a slow request stored after the
//    delete (Community#calendar_cache_version).
// 3. Channels: community-<id>-calendar-<year>-<month> for a month (the
//    name is also the server cache key, on purpose); meal-<id> for one
//    meal's page (a channel only; that page is not cached on the
//    server); and community-<id>-residents for any change to a resident
//    or unit, whose names are on every screen. The event name is always
//    "update".
// 4. The client subscribes to the month on screen and refetches on
//    "update" (data_store_calendar.js watchMonthChannels), dropping its
//    copies first so a fetch that was already on the wire cannot bring
//    back the old month (month_fetch.js refetch). It also subscribes to
//    the two neighbouring months and only evicts them from the client
//    caches, so the next navigation fetches fresh. A month's channel
//    stays open while the month is on screen or next to it, and its
//    handler checks which one when it fires. On the residents channel
//    it drops every cached month and meal and refetches what is on
//    screen (data_store_app.js handleResidentsUpdate).
// 5. The browser that caused the change is excluded from the meal-page
//    push: the server passes the client's socket_id, so a tap never
//    triggers its own refetch. The six requests of the sign-up list are
//    the exception (#237): each sends a push_token, and their push goes
//    to the sender too and names it. The page skips a push only when
//    every token in it is its own request that it has not given up on
//    (data_store_signup_requests.ts ownPush), so a request written after
//    the page stopped waiting for it still reaches the screen.
// 6. Pusher does not replay messages missed while the socket was down,
//    so every reconnect and every browser "online" event refetches
//    (data_store_app.js handleReconnect). After a Pusher reconnect, what
//    the residents channel's confirmation fetches (item 7) is left to
//    it. Midnight refetches the month too: the chips' words depend on
//    the day and nothing pushes then.
// 7. A push reaches this client only after Pusher has confirmed its
//    subscription, and a channel opens only when the first answer for
//    its month or meal is drawn. So when Pusher confirms the channel
//    of the month or meal on screen ("pusher:subscription_succeeded"),
//    the client fetches it once more (#112). The residents channel opens
//    with the first month, meal or hosts list drawn, and a rename pushes
//    only that channel, so its confirmation does what its push does: it
//    drops every copy of a month and a meal, and fetches again what is
//    on screen and the hosts list (also one still on the wire).
//    pusher-js subscribes every channel again after a reconnect, so all
//    of this also runs then.
// 8. With no VITE_PUSHER_KEY the client never connects and the app runs
//    without live updates; nothing else changes.
//
// This file is only the transport. It loads pusher-js outside the main
// bundle, so first paint does not wait for it (#44 item 1), and only
// after the page has loaded, when the main thread is idle. The library
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
  // No TLS option: pusher-js 8 always uses TLS unless forceTLS is
  // false. (It has no `encrypted` option; this call used to pass one.)
  real = new Pusher(import.meta.env.VITE_PUSHER_KEY, {
    cluster: import.meta.env.VITE_PUSHER_CLUSTER,
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
  // The library loads after the page's load event, when the main thread
  // is idle, so its download does not compete with the first screen.
  // Nothing is missed meanwhile: subscriptions wait in the queue, and
  // each confirmation fetches its data again (#112). An idle moment is
  // not waited for longer than 2 seconds. Safari has no
  // requestIdleCallback; there it loads on the next turn.
  function load() {
    import("pusher-js").then(function (mod) {
      connect(mod.default);
    });
  }
  function whenIdle() {
    if (typeof window.requestIdleCallback === "function") {
      window.requestIdleCallback(load, { timeout: 2000 });
    } else {
      setTimeout(load, 0);
    }
  }
  if (document.readyState === "complete") {
    whenIdle();
  } else {
    window.addEventListener("load", whenIdle, { once: true });
  }
}
