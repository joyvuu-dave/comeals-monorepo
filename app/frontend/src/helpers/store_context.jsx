import { createContext, useContext } from "react";

// How components reach the store: index.jsx provides it here, and
// function components read it with useStore().
export const StoreContext = createContext(null);

export function useStore() {
  const store = useContext(StoreContext);
  if (!store) {
    throw new Error("useStore called outside <StoreContext.Provider>");
  }
  return store;
}
