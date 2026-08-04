import { useEffect, useState } from "react";

var POLL_INTERVAL = 5 * 60 * 1000; // 5 minutes

var styles = {
  banner: {
    position: "fixed",
    top: 0,
    left: 0,
    right: 0,
    zIndex: 9999,
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    gap: "1rem",
    padding: "0.75rem 1rem",
    backgroundColor: "#444",
    color: "#fff",
    fontSize: "0.95rem",
  },
  button: {
    backgroundColor: "#CCDEEA",
    color: "#444",
    border: "none",
    borderRadius: "4px",
    padding: "0.4rem 1rem",
    cursor: "pointer",
    fontWeight: "bold",
    fontSize: "0.95rem",
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
  },
};

function VersionBanner() {
  var [updateAvailable, setUpdateAvailable] = useState(false);

  useEffect(function () {
    // Derive the running app's entry filename from the DOM rather than
    // a network fetch. This avoids a race condition: if a deploy finishes
    // between when the browser loaded index.html and when this component
    // mounts, a network-fetched baseline would reflect the new build while
    // the running code is old — the banner would never fire.
    var currentEntryFile = null;
    var script = document.querySelector(
      'script[type="module"][src^="/assets/"]',
    );
    if (script) {
      // Strip leading "/" so the value matches the manifest's "file" field
      // (manifest: "assets/index-abc.js", DOM: "/assets/index-abc.js")
      currentEntryFile = script.getAttribute("src").replace(/^\//, "");
    }

    var cancelled = false;
    var intervalId = setInterval(function () {
      if (!currentEntryFile) {
        return;
      }

      fetch("/.vite/manifest.json")
        .then(function (response) {
          if (!response.ok) {
            throw new Error("Failed to fetch manifest");
          }
          return response.json();
        })
        .then(function (manifest) {
          if (cancelled) return;
          var keys = Object.keys(manifest);
          for (var i = 0; i < keys.length; i++) {
            var entry = manifest[keys[i]];
            if (entry.isEntry && entry.file !== currentEntryFile) {
              setUpdateAvailable(true);
              clearInterval(intervalId);
              return;
            }
          }
        })
        .catch(function () {
          // Silently ignore fetch failures (user might be briefly offline)
        });
    }, POLL_INTERVAL);

    return function () {
      cancelled = true;
      clearInterval(intervalId);
    };
  }, []);

  if (!updateAvailable) {
    return null;
  }

  return (
    <div style={styles.banner}>
      <span>A new version is available.</span>
      <button
        style={styles.button}
        onClick={function () {
          window.location.reload();
        }}
      >
        Refresh
      </button>
    </div>
  );
}

export default VersionBanner;
