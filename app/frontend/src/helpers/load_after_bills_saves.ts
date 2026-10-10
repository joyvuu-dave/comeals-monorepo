import { notifyError } from "./bugsnag";

// The part of the DataStore this needs.
interface BillsSaves {
  finishBillsSaves(): Promise<boolean>;
}

// Loads a page with load() once the bills saves on their way are sent
// and answered, for a few seconds at most. A page load ends every
// request on its way (#150). If one of those saves was not saved, its
// message is on screen, and a load would take it away before anyone
// read it, so load() is not called and the page stays.
//
// The two callers come to this when something may be broken: the error
// page's Refresh, and the idle timer on a crashed page or on old code.
// The store may be what broke, and nothing else gets the screen off
// that page. So a wait that throws or fails is reported, and the page
// loads anyway.
export function loadAfterBillsSaves(
  store: BillsSaves,
  load: () => void,
): Promise<void> {
  let waited: Promise<boolean>;
  try {
    waited = store.finishBillsSaves();
  } catch (error) {
    waited = Promise.reject(error);
  }
  return waited.then(
    function (mayLoad) {
      if (mayLoad) load();
    },
    function (error) {
      notifyError(error);
      load();
    },
  );
}
