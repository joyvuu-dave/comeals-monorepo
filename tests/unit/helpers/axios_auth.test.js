import { describe, it, expect, beforeEach, vi } from "vitest";

// The interceptor reads the token cookie at request time. Tests must be able
// to flip that return value per-case, so the js-cookie mock is dynamic rather
// than a static lookup.
let currentToken;
vi.mock("js-cookie", () => ({
  default: {
    get: vi.fn((name) => (name === "token" ? currentToken : undefined)),
  },
}));

// Capture the interceptor callback that installAuthInterceptor() registers.
// We then invoke it directly with synthetic configs — this is the entire
// surface of the interceptor, and testing it this way avoids the complexity
// of spinning up real HTTP.
let capturedInterceptor;
vi.mock("axios", () => ({
  default: {
    interceptors: {
      request: {
        use: vi.fn((fn) => {
          capturedInterceptor = fn;
        }),
      },
    },
  },
}));

import { installAuthInterceptor } from "../../../app/frontend/src/helpers/axios_auth.js";

describe("installAuthInterceptor", () => {
  beforeEach(() => {
    currentToken = undefined;
    capturedInterceptor = undefined;
    installAuthInterceptor();
  });

  it("registers exactly one request interceptor on axios", async () => {
    const axios = (await import("axios")).default;
    expect(axios.interceptors.request.use).toHaveBeenCalledTimes(1);
    expect(typeof capturedInterceptor).toBe("function");
  });

  describe("when the token cookie is present", () => {
    beforeEach(() => {
      currentToken = "abc123.jwt.value";
    });

    it("attaches an Authorization: Bearer header to a config with no headers", () => {
      const out = capturedInterceptor({ url: "/api/v1/meals" });
      expect(out.headers.Authorization).toBe("Bearer abc123.jwt.value");
    });

    it("attaches the header to a config whose headers object is already present", () => {
      const out = capturedInterceptor({
        url: "/api/v1/meals",
        headers: { "Content-Type": "application/json" },
      });
      expect(out.headers.Authorization).toBe("Bearer abc123.jwt.value");
      // Must not drop existing headers — regression risk.
      expect(out.headers["Content-Type"]).toBe("application/json");
    });

    it("returns the same config object (axios requires the mutated config back)", () => {
      const input = { url: "/api/v1/meals" };
      const output = capturedInterceptor(input);
      expect(output).toBe(input);
    });

    it("works uniformly across HTTP verbs", () => {
      ["get", "post", "patch", "put", "delete"].forEach((method) => {
        const out = capturedInterceptor({ url: "/api/v1/meals", method });
        expect(out.headers.Authorization).toBe("Bearer abc123.jwt.value");
      });
    });

    it("overwrites a caller-supplied Authorization header with the cookie-derived one", () => {
      // Documenting current behavior: if a caller passes their own Authorization
      // header, the interceptor still overwrites it with the cookie token. The
      // logout flow in data_store.js relies on the overwrite being a no-op
      // (caller header matches cookie value) — see the logout regression test
      // in data_store.test.js. A future change that preserves caller headers
      // would need to update that flow too.
      const out = capturedInterceptor({
        url: "/api/v1/sessions/current",
        headers: { Authorization: "Bearer caller-provided" },
      });
      expect(out.headers.Authorization).toBe("Bearer abc123.jwt.value");
    });

    it("passes a raw legacy Key token through unchanged as the Bearer value", () => {
      // Pre-deploy cookies hold opaque Key tokens, not JWTs. The interceptor
      // doesn't know or care which format — it just wraps the value in Bearer.
      // The server's fallback path handles the demultiplexing.
      currentToken = "opaque-legacy-key-token";
      const out = capturedInterceptor({ url: "/api/v1/meals" });
      expect(out.headers.Authorization).toBe("Bearer opaque-legacy-key-token");
    });
  });

  describe("when the token cookie is absent", () => {
    beforeEach(() => {
      currentToken = undefined;
    });

    it("does not add any Authorization header to a blank config", () => {
      const out = capturedInterceptor({ url: "/api/v1/residents/name/xyz" });
      expect(out.headers?.Authorization).toBeUndefined();
    });

    it("does not touch an existing Authorization header set by the caller", () => {
      // Pre-login pages (e.g. the password-reset confirm page) never set the
      // token cookie but may still need to call token-protected endpoints —
      // the caller will handle auth another way. The interceptor must not
      // erase what it didn't set.
      const out = capturedInterceptor({
        url: "/api/v1/residents/name/xyz",
        headers: { Authorization: "Bearer caller-provided" },
      });
      expect(out.headers.Authorization).toBe("Bearer caller-provided");
    });

    it("treats an empty-string token as absent", () => {
      // Cookie.get returns undefined for a missing cookie, but if the token
      // cookie were explicitly set to "", `if (token)` correctly skips (empty
      // string is falsy). Locks this in — a future refactor to a ternary
      // could inadvertently send "Bearer ".
      currentToken = "";
      const out = capturedInterceptor({ url: "/api/v1/meals" });
      expect(out.headers?.Authorization).toBeUndefined();
    });
  });
});
