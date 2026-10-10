// The longest a page load waits for the cost saves. finishBillsSaves
// answers within 5 seconds by itself. This is for a broken store whose
// wait never answers.
const SAVES_WAIT_MS = 10 * 1000;

// Makes the function a crash page calls to load the page by itself:
// OuterErrorBoundary, and ErrorBoundary when the store could not take
// the note that the page crashed. The function loads at most once, so a
// tap during the wait, or a timer that runs out then, does not start a
// second load.
//
// A page load ends every request on its way, so the cost saves that wait
// are sent first (#150). sendWaitingSaves is the store's
// finishBillsSaves. Here nothing may stop the load: the store may be
// what broke, and nothing else gets the screen off the crash page. So a
// wait that throws, fails or never answers loads all the same. So does
// an answer that a save was not saved. A failure here is not reported:
// the crash was, and the store failing is most likely part of it.
export function crashPageLoader(
  sendWaitingSaves: () => unknown,
): (load: () => void) => void {
  let loading = false;
  return function loadAfterSaves(load: () => void) {
    if (loading) return;
    loading = true;
    let loaded = false;
    function loadOnce() {
      if (loaded) return;
      loaded = true;
      load();
    }
    setTimeout(loadOnce, SAVES_WAIT_MS);
    let waited: Promise<unknown>;
    try {
      // Promise.resolve: a broken store may hand back something that is
      // not a promise at all.
      waited = Promise.resolve(sendWaitingSaves());
    } catch {
      waited = Promise.resolve();
    }
    waited.then(loadOnce, loadOnce);
  };
}
