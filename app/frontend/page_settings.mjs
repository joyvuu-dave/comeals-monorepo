// Writes the page's keys into index.html as <meta> tags, from the
// VITE_* variables (.env locally, the job's env in CI). The app reads
// them with pageSetting() (src/helpers/page_settings.ts).
//
// This is only for the pages Vite itself sends: the dev server and
// `vite preview`, which the browser tests use. A page Rails sends gets
// its tags from Rails, which replaces these with the keys of the app that
// sends it (app/services/page_settings.rb). The Deploy workflow builds on
// staging and ships that build to production, so a key written here
// at build time would be staging's (#257).
//
// The names are the same in both places. spec/services/page_settings_spec.rb
// and tests/unit/page_settings_plugin.test.js pin them.

export const PAGE_SETTINGS = {
  "comeals-pusher-key": "VITE_PUSHER_KEY",
  "comeals-pusher-cluster": "VITE_PUSHER_CLUSTER",
  "comeals-bugsnag-api-key": "VITE_BUGSNAG_API_KEY",
};

export function pageSettingTags(env) {
  return Object.entries(PAGE_SETTINGS).map(function ([name, variable]) {
    return {
      tag: "meta",
      attrs: { name: name, content: env[variable] || "" },
      injectTo: "head",
    };
  });
}

export default function pageSettingsPlugin() {
  let env = {};
  return {
    name: "page-settings",
    configResolved(config) {
      env = config.env;
    },
    transformIndexHtml() {
      return pageSettingTags(env);
    },
  };
}
