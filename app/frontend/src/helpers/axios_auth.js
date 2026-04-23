// Install a global axios request interceptor that attaches the bearer token
// from the `token` cookie to every API request. This replaces the older
// pattern of appending `?token=${Cookie.get("token")}` to every URL.
//
// The server continues to accept `?token=` as a fallback during transition,
// but the SPA no longer relies on it — URLs are cleaner and tokens stop
// leaking into server logs and Referer headers.
import axios from "axios";
import Cookie from "js-cookie";

export function installAuthInterceptor() {
  axios.interceptors.request.use((config) => {
    const token = Cookie.get("token");
    if (token) {
      config.headers = config.headers || {};
      config.headers.Authorization = `Bearer ${token}`;
    }
    return config;
  });
}
