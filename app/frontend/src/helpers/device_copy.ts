import { get as kvGet } from "idb-keyval";

// The meal page and the calendar read their copy on the device
// (IndexedDB) before they ask the server, so the page shows sooner. In
// WebKit such a read can stop answering, with neither a value nor an
// error. The page then never asked the server and said "loading..."
// for good (#132). So a read gets this long.
//
// A read of one key answers in a few milliseconds, so 500 ms is far
// longer than any read that works, and short enough that a person
// waiting for the page hardly notices it. A read slower than this
// only loses the early draw from the copy: the page shows the
// server's answer instead.
export const DEVICE_READ_LIMIT_MS = 500;

// The copy saved under `key`, or undefined when there is none, or when
// the read did not answer within DEVICE_READ_LIMIT_MS. A read that
// answers after the limit is ignored: by then the caller has asked the
// server, and an old copy must not replace the server's answer. A read
// that fails within the limit still rejects, so each caller keeps its
// own way of handling a broken copy.
export function readDeviceCopy<T>(key: string): Promise<T | undefined> {
  return new Promise(function (resolve, reject) {
    const timer = setTimeout(function () {
      resolve(undefined);
    }, DEVICE_READ_LIMIT_MS);
    kvGet<T>(key).then(
      function (value) {
        clearTimeout(timer);
        resolve(value);
      },
      function (error: unknown) {
        clearTimeout(timer);
        reject(error);
      },
    );
  });
}
