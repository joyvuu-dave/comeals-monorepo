import { describe, it, expect, beforeEach } from "vitest";
import toastStore from "../../../app/frontend/src/stores/toast_store.js";

// The app shows one toast at a time: every caller uses replaceAll, the
// toast container removes a toast by id (its timer, or the dismiss
// button), and the calendar clears them all.
describe("toastStore", () => {
  beforeEach(() => {
    toastStore.clearAll();
  });

  it("replaceAll shows one toast and hands back its id", () => {
    const id = toastStore.replaceAll("Saved.", "success");

    expect(toastStore.toasts).toEqual([
      { id: id, message: "Saved.", type: "success" },
    ]);
  });

  it("replaceAll takes the place of the toast on screen", () => {
    toastStore.replaceAll("One", "info");
    toastStore.replaceAll("Two", "error");

    expect(toastStore.toasts.map((t) => [t.message, t.type])).toEqual([
      ["Two", "error"],
    ]);
  });

  // A new id is what makes the container start a new timer, so the same
  // message shown again stays up for its full time.
  it("gives the same message a new id each time", () => {
    const first = toastStore.replaceAll("Saved.", "success");
    const second = toastStore.replaceAll("Saved.", "success");

    expect(second).not.toBe(first);
    expect(toastStore.toasts.map((t) => t.id)).toEqual([second]);
  });

  it("removeToast removes the toast with that id", () => {
    const id = toastStore.replaceAll("Saved.", "success");

    toastStore.removeToast(id);

    expect(toastStore.toasts).toEqual([]);
  });

  // The timer of a toast that was replaced still fires, with the old id.
  it("removeToast with a replaced toast's id leaves the new toast", () => {
    const old = toastStore.replaceAll("One", "info");
    toastStore.replaceAll("Two", "info");

    toastStore.removeToast(old);

    expect(toastStore.toasts.map((t) => t.message)).toEqual(["Two"]);
  });

  it("clearAll removes the toast", () => {
    toastStore.replaceAll("Saved.", "success");

    toastStore.clearAll();

    expect(toastStore.toasts).toEqual([]);
  });
});
