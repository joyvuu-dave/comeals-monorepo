// Puts one of the page's keys into the test page, the way Rails and
// Vite write it (app/frontend/src/helpers/page_settings.ts). render_setup.js
// takes them all out after each test, so a key never carries over to the
// next one.
export function setPageSetting(name, value) {
  let tag = document.head.querySelector(`meta[name="${name}"]`);
  if (!tag) {
    tag = document.createElement("meta");
    tag.name = name;
    document.head.appendChild(tag);
  }
  tag.content = value;
}

export function clearPageSettings() {
  document.head
    .querySelectorAll('meta[name^="comeals-"]')
    .forEach(function (tag) {
      tag.remove();
    });
}
