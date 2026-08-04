import { createContext, useContext } from "react";

// The hooks-era replacement for mobx-react's inject("store"). index.jsx
// provides the store; function components read it with useStore().
export const StoreContext = createContext(null);

export function useStore() {
  const store = useContext(StoreContext);
  if (!store) {
    throw new Error("useStore called outside <StoreContext.Provider>");
  }
  return store;
}
