// #150. When the page is hidden or closed, the bills edits only this
// page holds are handed to the browser, which can finish a request sent
// with fetch keepalive after the page is gone. index.jsx calls this
// once, for every page: a save for a meal the person left can still be
// on its way while the calendar shows.
//
// - visibilitychange to hidden, and pagehide: each cook row that waits
//   to save is sent at once (sendBillsBeforeHidden). On a phone,
//   visibilitychange to hidden is the last event a page can count on:
//   the browser may close a page in the background with no other event.
//   pagehide covers a desktop browser closing the tab, and a reload.
// - pagehide, when the browser does not keep the page in its
//   back-forward cache (event.persisted is false): the page is going
//   away, and the browser ends every XMLHttpRequest with it. So each
//   bills save on its way is sent again, with keepalive and the same key
//   (sendBillsAgainBeforeClose). It goes after the rows, whose saves go
//   with keepalive already and are not sent twice. A page the browser
//   keeps may come back, so its saves on their way are left alone.
//
// A row or a save with nothing to send sends nothing, so both events
// firing is fine. Returns the function that stops listening.
// The two store actions this needs (data_store_bills.ts).
interface BillsSender {
  sendBillsBeforeHidden(): void;
  sendBillsAgainBeforeClose(): void;
}

export function sendBillsOnPageClose(store: BillsSender): () => void {
  function onVisibilityChange(): void {
    if (document.visibilityState === "hidden") store.sendBillsBeforeHidden();
  }
  function onPageHide(event: PageTransitionEvent): void {
    store.sendBillsBeforeHidden();
    if (!event.persisted) store.sendBillsAgainBeforeClose();
  }
  document.addEventListener("visibilitychange", onVisibilityChange);
  window.addEventListener("pagehide", onPageHide);
  return function () {
    document.removeEventListener("visibilitychange", onVisibilityChange);
    window.removeEventListener("pagehide", onPageHide);
  };
}
