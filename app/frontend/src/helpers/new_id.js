// A fresh id for a record that exists only in the browser (a blank bill
// row on the meal page). crypto.randomUUID() is the right call, but it
// only exists in a secure context: https, or http on localhost. The dev
// server opened from another device on the LAN (http://192.168.x.x:3036)
// has no randomUUID, and the meal page would throw (#75). So fall back to
// crypto.getRandomValues, which every context has, and build the same
// kind of value: a version 4 UUID.
export function newId() {
  if (typeof crypto.randomUUID === "function") return crypto.randomUUID();
  return uuidV4FromRandomBytes();
}

function uuidV4FromRandomBytes() {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant
  const hex = Array.from(bytes, function (b) {
    return b.toString(16).padStart(2, "0");
  }).join("");
  return (
    hex.slice(0, 8) +
    "-" +
    hex.slice(8, 12) +
    "-" +
    hex.slice(12, 16) +
    "-" +
    hex.slice(16, 20) +
    "-" +
    hex.slice(20)
  );
}
