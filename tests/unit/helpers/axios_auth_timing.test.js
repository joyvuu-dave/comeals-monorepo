import { describe, it, expect, vi } from "vitest";

// The real axios, with the cookie mock, so this checks when the token is
// read, not only how the header is written (axios_auth.test.js).
vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));
import Cookie from "js-cookie";
import axios from "axios";
import { installAuthInterceptor } from "../../../app/frontend/src/helpers/axios_auth.js";

// Logout takes the token away right after it hands the bills saves on
// their way to the browser again (#150), so the token must be read when
// a request is made, not later.
describe("installAuthInterceptor, with the real axios", () => {
  it("reads the token when the request is made", async () => {
    installAuthInterceptor();
    let sent;
    const adapter = (config) => {
      sent = config.headers.Authorization;
      return Promise.resolve({ data: {}, status: 200, headers: {}, config });
    };

    const request = axios({ url: "/api/v1/meals/1/bills", adapter });
    Cookie.remove("token", { path: "/" });
    await request;

    expect(sent).toBe("Bearer test-token");
  });
});
