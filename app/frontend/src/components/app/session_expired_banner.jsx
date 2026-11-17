import { observer } from "mobx-react-lite";
import { useStore } from "../../helpers/store_context";

function SessionExpiredBanner() {
  const store = useStore();
  if (!store.authExpired) {
    return null;
  }

  return (
    // A section with a name is a landmark, so a screen reader can find
    // the banner in its list of the page's parts.
    <section className="app-banner app-banner--error" aria-label="Signed out">
      <span>Heads up — you've been signed out.</span>
      <button
        className="app-banner__button"
        onClick={function () {
          store.logout();
          window.location.href = "/";
        }}
      >
        Sign in
      </button>
    </section>
  );
}

export default observer(SessionExpiredBanner);
