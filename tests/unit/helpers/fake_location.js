// jsdom does not navigate: assigning window.location.href or calling
// window.location.reload() prints "Not implemented" to stderr and does
// nothing, and the real Location object refuses to be spied on. This
// replaces window.location with a plain object for one test, so the
// test can read what the page asked for. Call restore() when done.
import { vi } from "vitest";

export function fakeLocation(fields = {}) {
  const descriptor = Object.getOwnPropertyDescriptor(window, "location");
  const location = {
    href: "http://localhost:3000/",
    pathname: "/",
    host: "localhost:3000",
    reload: vi.fn(),
    ...fields,
  };
  Object.defineProperty(window, "location", {
    value: location,
    configurable: true,
    writable: true,
  });
  return {
    location,
    restore() {
      Object.defineProperty(window, "location", descriptor);
    },
  };
}
