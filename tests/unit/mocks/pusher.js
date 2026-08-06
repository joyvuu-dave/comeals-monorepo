// The shared pusher-js mock. Use it with the redirect form:
//
//   vi.mock("pusher-js", () => import("../mocks/pusher.js"));
//
// Every constructed instance is recorded on MockPusher.instances, so
// a test can reach the store's connection handlers:
//
//   const Pusher = (await import("pusher-js")).default;
//   const instance = Pusher.instances[Pusher.instances.length - 1];
import { vi } from "vitest";

class MockPusher {
  constructor() {
    this.connection = {
      bind: vi.fn(),
      socket_id: "test-socket",
    };
    this.subscribe = vi.fn(() => ({ bind: vi.fn(), name: "test-channel" }));
    this.unsubscribe = vi.fn();
    MockPusher.instances.push(this);
  }
}
MockPusher.instances = [];

export default MockPusher;
