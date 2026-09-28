// The shared pusher-js mock. Use it with the redirect form:
//
//   vi.mock("pusher-js", () => import("../mocks/pusher.js"));
//
// Every constructed instance is recorded on MockPusher.instances, so
// a test can reach the store's connection handlers:
//
//   const Pusher = (await import("pusher-js")).default;
//   const instance = Pusher.instances[Pusher.instances.length - 1];
//
// Like pusher-js, subscribe returns the one channel it keeps under a
// name, until unsubscribe closes it, so a test can read what was bound
// on it: instance.channels["meal-1"].bind.
import { vi } from "vitest";

class MockPusher {
  constructor() {
    this.connection = {
      bind: vi.fn(),
      socket_id: "test-socket",
    };
    this.channels = {};
    this.subscribe = vi.fn((name) => {
      this.channels[name] ||= { bind: vi.fn(), name };
      return this.channels[name];
    });
    this.unsubscribe = vi.fn((name) => {
      delete this.channels[name];
    });
    MockPusher.instances.push(this);
  }
}
MockPusher.instances = [];

export default MockPusher;
