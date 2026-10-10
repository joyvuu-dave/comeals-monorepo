// An axios call on a connection that never answers: the phone lost its
// connection after the request left, and the browser keeps waiting.
//
// Use it as the mock axios's implementation for one call:
//
//   axios.mockImplementationOnce(deadConnection);
//
// It does what axios does then. A request with a `timeout` is ended after
// that many milliseconds and rejected with an error that has a request
// but no response (code ECONNABORTED). A request with no `timeout` waits
// for ever, so its promise never settles.
export function deadConnection(config) {
  return new Promise((_resolve, reject) => {
    if (!config.timeout) return;
    setTimeout(() => {
      reject(
        Object.assign(new Error(`timeout of ${config.timeout}ms exceeded`), {
          code: "ECONNABORTED",
          config,
          request: {},
        }),
      );
    }, config.timeout);
  });
}
