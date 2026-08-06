// The shared axios mock. Use it with the redirect form, which vitest
// hoists safely:
//
//   vi.mock("axios", () => import("../mocks/axios.js"));
//
// It is a superset of what any test needs: callable (the api helper
// calls axios({...}) directly) and with the method/interceptor
// surface. Every function resolves a bare 200 by default; a test that
// cares about the response sets it explicitly:
//
//   axios.get.mockResolvedValue({ status: 200, data: EVENT });
//
// Defaults set with vi.fn(impl) here survive vi.clearAllMocks() —
// clearing wipes recorded calls, not implementations.
import { vi } from "vitest";

const mockAxios = vi.fn(() => Promise.resolve({ status: 200 }));
mockAxios.get = vi.fn(() => Promise.resolve({ status: 200, data: {} }));
mockAxios.post = vi.fn(() => Promise.resolve({ status: 200, data: {} }));
mockAxios.patch = vi.fn(() => Promise.resolve({ status: 200, data: {} }));
mockAxios.delete = vi.fn(() => Promise.resolve({ status: 200, data: {} }));
mockAxios.interceptors = {
  response: { use: vi.fn(), eject: vi.fn() },
  request: { use: vi.fn(), eject: vi.fn() },
};

export default mockAxios;
