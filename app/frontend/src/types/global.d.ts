// The one global the SPA keeps on window: the Pusher client wrapper and
// the two live channels (helpers/pusher_client.js, index.jsx). Typed here
// so a store written in TypeScript can read window.Comeals without a cast.

export interface PusherChannel {
  name: string;
  bind(event: string, callback: (...args: unknown[]) => void): void;
}

export interface PusherClient {
  subscribe(name: string): PusherChannel;
  unsubscribe(name: string): void;
  connection: {
    bind(event: string, callback: (...args: unknown[]) => void): void;
    readonly socket_id: string | null;
  };
}

declare global {
  interface Window {
    Comeals: {
      pusher: PusherClient;
      socketId: string | null;
      mealChannel: PusherChannel | null;
      calendarChannel: PusherChannel | null;
    };
  }
}
