# Plan: class components to hooks, `inject()` to context

Written 2026-08-04. Status: done (2026-08-04). Every "Done when" check
passes. One note: mobx-react-lite is pinned to the 4.x line, not 5.0 —
5.0 requires mobx 7 and this app is on mobx 6. mobx-react 9 wrapped
mobx-react-lite 4, so the running code is unchanged.

## The issue

The frontend dependencies are current, but most of the component code is written in a style React left behind years ago.

- **26 of 34 components are class components.** They work, and React has said classes will keep working. But hooks do not work inside them, so every new React feature is unavailable there, and every edit to one of these files is written in a style nothing new uses.
- **20 components get the store through `inject("store")`** from `mobx-react`. `inject` is the pre-hooks way to read from context. Since mobx-react 6 (2019) the maintainers keep it only for backward compatibility and point everyone to React context plus `observer`. It still ships in mobx-react 9, but it is the part of the library most likely to be dropped in a future major version. It is also the only reason we need full `mobx-react` instead of the smaller `mobx-react-lite`.

Neither is urgent. The reason to have a plan anyway: when a future mobx-react major drops `inject`, we want the migration to already be routine, not a scramble.

## The target pattern

The codebase already contains it. `BillEdit` in `app/frontend/src/components/meal/cooks_box.jsx` is a function component using `useState`/`useRef`, wrapped in `observer`. The only change to that pattern here is where the store comes from: a context hook instead of `inject`.

```jsx
// app/frontend/src/helpers/store_context.jsx  (new file, step 1)
import { createContext, useContext } from "react";

export const StoreContext = createContext(null);

export function useStore() {
  const store = useContext(StoreContext);
  if (!store) {
    throw new Error("useStore called outside <StoreContext.Provider>");
  }
  return store;
}
```

A migrated component looks like:

```jsx
import { observer } from "mobx-react";
import { useStore } from "../../helpers/store_context";

const CloseButton = observer(() => {
  const store = useStore();
  // ...
});
```

Router access migrates the same way: a function component calls `useNavigate`/`useParams` directly, so it no longer needs the `withRouter` wrapper in `app/frontend/src/helpers/with_router.jsx`.

## Rules that keep this safe

1. **Render test first.** No component is converted until it has a render test under `tests/unit/components/`. The harness (stub store in a `Provider`, `@testing-library/react`) was set up 2026-08-04; six components are covered already. The test is written against the class version, must pass, and must pass unchanged against the hooks version. The test pins behavior, so the conversion cannot silently change it.
2. **One component per commit.** A conversion commit changes one component file and, if needed, its test's `Provider` wrapper. Nothing else. A bad conversion reverts cleanly.
3. **Behavior changes are separate commits.** If a conversion exposes something worth fixing, fix it before or after, never inside the conversion commit.
4. **Every commit passes the full gate:** `npx vitest run`, `npm run lint`, and the Playwright suites (`npm run test:e2e`, `npm run test:integration`). The visual snapshots in `tests/e2e/visual.spec.js` catch layout drift the unit tests cannot.
5. **`error_boundary.jsx` stays a class.** React has no hook for `componentDidCatch`. This is the one permanent exception; the plan is done when it is the only class left.

## Translation table

| Class pattern                                                        | Hooks pattern                                                                  |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| `this.state` / `this.setState`                                       | `useState`                                                                     |
| `componentDidMount` + `componentWillUnmount`                         | one `useEffect` with a cleanup return                                          |
| `_isMounted` guard (see `history/show.jsx`)                          | the effect's cleanup cancels or flags; prefer an `AbortController` for fetches |
| instance fields holding timers (see `toast_container.jsx` `_timers`) | `useRef` holding the same map                                                  |
| `inject("store")(observer(...))`                                     | `observer` + `useStore()`                                                      |
| `withRouter(...)` + `this.props.history.push`                        | `useNavigate()`                                                                |
| `constructor` binding                                                | none needed                                                                    |

Watch for two traps:

- `observer` must wrap the function component itself, or store changes stop re-rendering it. The render tests catch this: several assert that the component updates when the store changes after mount.
- An empty `useEffect` dependency array is not the same as `componentDidMount` when the effect reads props or store values. Let the eslint `react-hooks` plugin (already configured) decide the array; do not silence it.

## Order of work

Small and already-tested first, so the routine is proven before it touches anything that matters.

1. **Bootstrap.** Add `store_context.jsx`. In `app/frontend/src/index.jsx`, wrap the tree in `<StoreContext.Provider value={store}>` alongside the existing mobx-react `<Provider>`. Both coexist for the whole migration.
2. **Already-tested components** (render tests exist): `toast_container.jsx`, `session_expired_banner.jsx`, `load_status.jsx`, `cooks_box.jsx`.
3. **Small store-free classes** (test, then convert): `version_banner.jsx`, `scroll_to_top.jsx`, `confirm_modal.jsx`, `webcal_links.jsx`, `day_picker_input.jsx`, `guest_dropdown.jsx`, `password_new.jsx`, `rotations/show.jsx`, `history/show.jsx`.
4. **Meal page components**: `close_button.jsx`, `button_bar.jsx`, `attendees_box.jsx`, `date_box.jsx`, `extras.jsx`, `header.jsx`, `info_box.jsx`, `menu_box.jsx`, `meals/edit.jsx`. This is the page people use most; by now the routine is boring, which is the point.
5. **Forms**: `events/new.jsx`, `events/edit.jsx`, `common_house_reservations/new.jsx`, `common_house_reservations/edit.jsx`, `guest_room_reservations/new.jsx`, `guest_room_reservations/edit.jsx`, `residents/login.jsx`.
6. **Calendar last**: `calendar/show.jsx`, `calendar/side_bar.jsx`. Largest and most stateful; everything learned lands here.
7. **Teardown.** When `grep -rn 'inject' app/frontend/src` is empty: remove the mobx-react `<Provider>` from `index.jsx`, delete `with_router.jsx` if no class needs it, and switch `mobx-react` to `mobx-react-lite` in `package.json` (it exports the same `observer` for function components). Update the test helper's `Provider` wrapper to `StoreContext.Provider`.

## Done when

- `grep -rln "extends Component" app/frontend/src` returns only `error_boundary.jsx`.
- `grep -rn "inject" app/frontend/src` returns nothing.
- `mobx-react` is gone from `package.json`, replaced by `mobx-react-lite`.
- Every converted component has a render test.
- Visual snapshots unchanged.

## What this plan is not

Not a redesign. No component's markup, styling, or behavior changes. No store code changes — the MST stores and `data_store.js` are untouched. If a conversion cannot be done without a behavior change, stop and write down why before proceeding.
