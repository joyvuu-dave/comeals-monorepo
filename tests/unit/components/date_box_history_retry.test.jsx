// History's code is a chunk of its own, so after a deploy a meal page
// loaded before it can ask for a file the server no longer has. It loads
// through lazyRetry, like the calendar and the meal page, so the page
// reloads once instead of showing the error page.
import { describe, expect, it, vi } from "vitest";

const lazyRetry = vi.fn(function (importFn) {
  return importFn;
});
vi.mock("../../../app/frontend/src/helpers/lazy_retry.js", () => ({
  default: lazyRetry,
}));

describe("the meal page's History link", () => {
  it("loads History through lazyRetry", async () => {
    // date_box.jsx points react-modal at #root when it loads.
    document.body.innerHTML = '<div id="root"></div>';
    await import("../../../app/frontend/src/components/meal/date_box.jsx");

    expect(lazyRetry).toHaveBeenCalledTimes(1);
    const historyModule = await lazyRetry.mock.calls[0][0]();
    expect(historyModule.default).toBeDefined();
  });
});
