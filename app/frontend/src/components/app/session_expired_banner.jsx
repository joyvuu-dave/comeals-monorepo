import { observer } from "mobx-react-lite";
import { useStore } from "../../helpers/store_context";

function SessionExpiredBanner() {
  const store = useStore();
  if (!store.authExpired) {
    return null;
  }

  return (
    <div className="app-banner app-banner--error">
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
    </div>
  );
}

export default observer(SessionExpiredBanner);
