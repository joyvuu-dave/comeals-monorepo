// Preloads the calendar's code from index.html, so it downloads beside
// the main bundle instead of after it (#44). index.html is one page for
// every address (FallbackController serves it), so the preload is a
// small script that adds the links only on a calendar address. The login
// page and the meal page do not run the calendar's code, and on a slow
// phone its 77 kB download took bandwidth from their first screen.
//
// The script goes right after <meta charset>, before the stylesheet: a
// script after a stylesheet that is still loading waits for it. It is
// old JavaScript (ES5), like the browser check, because it runs before
// the browser check has turned an old browser away.
//
// bin/bundle-budget fails the build when the calendar chunk has no
// preload, because this finds the chunk by the file name
// calendar/show.jsx, and a move would otherwise drop the preload with no
// error.

const CHARSET = '<meta charset="utf-8" />';

function preloadScript(files) {
  return (
    '<script id="calendar-preload">\n' +
    "      (function () {\n" +
    '        if (window.location.pathname.indexOf("/calendar/") !== 0) return;\n' +
    `        var files = ${JSON.stringify(files)};\n` +
    "        for (var i = 0; i < files.length; i++) {\n" +
    '          var link = document.createElement("link");\n' +
    '          link.rel = "modulepreload";\n' +
    "          link.href = files[i];\n" +
    "          document.head.appendChild(link);\n" +
    "        }\n" +
    "      })();\n" +
    "    </script>"
  );
}

export default function preloadCalendarPlugin() {
  return {
    name: "preload-calendar",
    transformIndexHtml: {
      order: "post",
      handler(html, ctx) {
        if (!ctx.bundle) return; // dev server: nothing to preload
        const chunk = Object.values(ctx.bundle).find(
          (c) =>
            c.facadeModuleId && c.facadeModuleId.endsWith("calendar/show.jsx"),
        );
        if (!chunk) return;
        // The chunk cannot execute until its static imports are also
        // loaded, so preload those too — minus the ones the entry
        // already loads (Vite emits its own modulepreloads for them).
        const entry = Object.values(ctx.bundle).find((c) => c.isEntry);
        const covered = new Set([entry.fileName, ...(entry.imports || [])]);
        const files = [chunk.fileName, ...(chunk.imports || [])]
          .filter((f) => !covered.has(f))
          .map((f) => "/" + f);
        if (!html.includes(CHARSET)) {
          throw new Error(
            `preload-calendar: index.html has no ${CHARSET} line to put the calendar preload after`,
          );
        }
        return html.replace(
          CHARSET,
          () => `${CHARSET}\n    ${preloadScript(files)}`,
        );
      },
    },
  };
}
