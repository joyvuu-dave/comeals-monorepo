import { useRef } from "react";
import { newId } from "./new_id";

export type RequestKeyHeaders = { "Idempotency-Key": string };

// The Idempotency-Key of a calendar form's save (ADR 0015). A phone that
// sends a save and gets no answer cannot tell whether it was saved, and
// the person presses the button again. The server keeps the key of every
// save it wrote, so a second send with the same key is answered with the
// first answer and writes nothing: no event saved twice, no "taken" for
// the person's own booking, no "doesn't exist" for their own delete.
//
// The key stays the same while the body stays the same, and is new when
// the body changes: a press after the person changed a field is a new
// request, and the server would refuse an old key with a new body (422).
//
//   const keyed = useRequestKey();
//   axios.post(url, ...keyed({ title, ... }));
//
// keyed(body) returns the two arguments after the URL: the body, and the
// request config with the header.
export default function useRequestKey() {
  const last = useRef<{ text: string; key: string } | null>(null);
  return function keyed<Body>(
    body: Body,
  ): [Body, { headers: RequestKeyHeaders }] {
    const text = JSON.stringify(body);
    if (last.current === null || last.current.text !== text) {
      last.current = { text: text, key: newId() };
    }
    return [body, { headers: requestKeyHeaders(last.current.key) }];
  };
}

// The header for a key, as a Structured Field string (RFC 9651): the key
// between double quotes. Every key this app makes is a UUID or letters,
// digits and hyphens, so nothing in it needs a backslash.
export function requestKeyHeaders(key: string): RequestKeyHeaders {
  return { "Idempotency-Key": `"${key}"` };
}
