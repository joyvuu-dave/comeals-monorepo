// The keys the page needs from the app that sent it: the Pusher key and
// cluster, and the Bugsnag key. They are <meta> tags in the page, not
// values built into the JavaScript, because the Deploy workflow builds
// on staging and ships that same build to production (#257). Rails
// writes them as it sends the page (app/services/page_settings.rb);
// under `vite dev` and `vite preview`, Vite writes them from the VITE_*
// variables (app/frontend/page_settings.mjs).
//
// A tag that is missing or empty reads as "": no key. Each caller treats
// that as "off", the way it treated an empty VITE_* variable.

export type PageSettingName =
  "comeals-pusher-key" | "comeals-pusher-cluster" | "comeals-bugsnag-api-key";

export function pageSetting(name: PageSettingName): string {
  const tag = document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`);
  return tag ? tag.content : "";
}
