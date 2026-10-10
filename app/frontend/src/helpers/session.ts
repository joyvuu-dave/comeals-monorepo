import Cookie from "js-cookie";

// The session lives in the cookies login.jsx writes. Logout, and "Sign
// in" in the signed-out banner, remove them just before the page loads
// "/" again (data_store_app.js). Until the new page arrives, the old one
// keeps running, and work it started before can still go on: a calendar
// whose code arrived a moment late mounts, or a month read from the
// device ends and goes on to ask the server. A request built then from
// the cookies named the community "undefined" (#153). So each request
// that needs the session reads it here, at the moment it is built, and
// is not sent when the session is gone. The same goes for a Pusher
// channel, whose name holds the community id.

// A cookie's value, or null when it is not there. A cookie that holds
// the text "undefined" was written from a missing value (js-cookie
// writes String(value)), so it counts as not there.
function cookie(name: string): string | null {
  const value = Cookie.get(name);
  if (value === undefined || value === "undefined") return null;
  return value;
}

// True while the page has a session: the token the API asks for.
export function signedIn(): boolean {
  return cookie("token") !== null;
}

// The community's id, or null when the page has no session. The Pusher
// channels are named with it.
export function communityId(): string | null {
  return cookie("community_id");
}

// The path of one of the community's API endpoints ("hosts",
// "calendar/2026-01-15"), or null when the page has no community id, so
// the request must not be sent.
export function communityApiPath(endpoint: string): string | null {
  const id = communityId();
  if (id === null) return null;
  return `/api/v1/communities/${id}/${endpoint}`;
}
