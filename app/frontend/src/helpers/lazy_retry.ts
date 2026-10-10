// React.lazy loads a page's code from its own file (a chunk). After a
// deploy, a page loaded before it can ask for a chunk the server no
// longer has, and the import fails. The page then reloads once, to get
// the new build. A second failure in a row is a real error, and it goes
// to the error page.
//
// `beforeReload` runs just before the reload. The reload ends every
// request on its way, and WebKit ends them as soon as it starts, before
// the page fires pagehide. index.jsx hands the bills saves on their way
// to the browser there (#150).
export function lazyRetry<T>(
  importFn: () => Promise<T>,
  beforeReload: () => void,
): () => Promise<T> {
  return function () {
    return importFn().catch(function (err: unknown) {
      if (!sessionStorage.getItem("chunk_retry")) {
        sessionStorage.setItem("chunk_retry", "1");
        beforeReload();
        window.location.reload();
        return new Promise<T>(function () {});
      }
      sessionStorage.removeItem("chunk_retry");
      throw err;
    });
  };
}
