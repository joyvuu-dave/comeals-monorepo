// Loads pusher-js outside the main bundle, so first paint does not wait
// for it (#44 item 1). The library is 60 KB and nothing on screen needs
// it — its job is live updates and cache invalidation.
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

export function startPusher() {
  if (started) return;
  started = true;
  import("pusher-js").then(function (mod) {
    const Pusher = mod.default;
    // Pusher public key + cluster from env vars (VITE_PUSHER_KEY,
    // VITE_PUSHER_CLUSTER). Local dev: .env file (committed defaults).
    real = new Pusher(import.meta.env.VITE_PUSHER_KEY, {
      cluster: import.meta.env.VITE_PUSHER_CLUSTER,
      encrypted: true,
    });
    const pending = queue.splice(0);
    pending.forEach(function (fn) {
      fn(real);
    });
  });
}
