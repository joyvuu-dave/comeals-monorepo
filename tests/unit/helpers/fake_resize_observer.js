// jsdom has no ResizeObserver. This one says which element it watches,
// and a test calls `resized` to say the element changed size, the way a
// browser calls the callback. A test file puts it in place with
// vi.stubGlobal("ResizeObserver", FakeResizeObserver) and empties
// FakeResizeObserver.made before each test.
export default class FakeResizeObserver {
  static made = [];

  constructor(callback) {
    this.callback = callback;
    this.watching = [];
    FakeResizeObserver.made.push(this);
  }

  observe(element) {
    this.watching.push(element);
    // A browser calls the callback once when it starts watching.
    this.callback([]);
  }

  disconnect() {
    this.watching = [];
  }

  resized() {
    this.callback([]);
  }
}

// Make the element say it is this many pixels tall, as a browser would
// after it lays out the page. jsdom lays out nothing, so every element
// is 0 pixels tall there.
export function makeTall(element, height) {
  Object.defineProperty(element, "offsetHeight", {
    configurable: true,
    value: height,
  });
}
