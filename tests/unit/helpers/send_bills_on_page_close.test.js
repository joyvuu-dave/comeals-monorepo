import { describe, it, expect, vi, afterEach } from "vitest";
import { sendBillsOnPageClose } from "../../../app/frontend/src/helpers/send_bills_on_page_close";

// #150. When the page is hidden or closed, the bills edits only this
// page holds are handed to the browser, with fetch keepalive. The app
// listens once, for every page: a save for a meal the person left can
// still be on its way while the calendar shows.
describe("sendBillsOnPageClose", () => {
  let stopListening = () => {};

  afterEach(() => {
    stopListening();
    delete document.visibilityState;
  });

  function listen() {
    const store = {
      sendBillsBeforeHidden: vi.fn(),
      sendBillsAgainBeforeClose: vi.fn(),
    };
    stopListening = sendBillsOnPageClose(store);
    return store;
  }

  function setVisibility(state) {
    Object.defineProperty(document, "visibilityState", {
      value: state,
      configurable: true,
    });
    document.dispatchEvent(new Event("visibilitychange"));
  }

  function pageHide(persisted) {
    const event = new Event("pagehide");
    event.persisted = persisted;
    window.dispatchEvent(event);
  }

  // On a phone, visibilitychange to hidden is the last event a page can
  // count on: the browser may close a page in the background with no
  // other event.
  it("sends the rows that wait to save when the page is hidden", () => {
    const store = listen();

    setVisibility("hidden");

    expect(store.sendBillsBeforeHidden).toHaveBeenCalledTimes(1);
    expect(store.sendBillsAgainBeforeClose).not.toHaveBeenCalled();
  });

  it("sends nothing when the page shows again", () => {
    const store = listen();

    setVisibility("visible");

    expect(store.sendBillsBeforeHidden).not.toHaveBeenCalled();
  });

  // The browser ends every XMLHttpRequest with the page, so each save
  // on its way is sent again with keepalive. The rows go first, so their
  // saves, which go with keepalive already, are not sent twice.
  it("sends the rows that wait to save, then the saves on their way again, when the page closes", () => {
    const store = listen();

    pageHide(false);

    expect(store.sendBillsBeforeHidden).toHaveBeenCalledTimes(1);
    expect(store.sendBillsAgainBeforeClose).toHaveBeenCalledTimes(1);
    expect(
      store.sendBillsBeforeHidden.mock.invocationCallOrder[0],
    ).toBeLessThan(store.sendBillsAgainBeforeClose.mock.invocationCallOrder[0]);
  });

  // The browser keeps the page in its back-forward cache, so the page
  // may come back, and its saves on their way are left alone.
  it("does not send the saves on their way again when the browser keeps the page", () => {
    const store = listen();

    pageHide(true);

    expect(store.sendBillsBeforeHidden).toHaveBeenCalledTimes(1);
    expect(store.sendBillsAgainBeforeClose).not.toHaveBeenCalled();
  });

  it("stops listening when asked", () => {
    const store = listen();
    stopListening();

    setVisibility("hidden");
    pageHide(false);

    expect(store.sendBillsBeforeHidden).not.toHaveBeenCalled();
    expect(store.sendBillsAgainBeforeClose).not.toHaveBeenCalled();
  });
});
