import { describe, it, expect, beforeEach } from "vitest";
import toastStore from "../../../app/frontend/src/stores/toast_store.js";

describe("toastStore", () => {
  beforeEach(() => {
    toastStore.clearAll();
  });

  it("adds a toast and hands back its id", () => {
    const id = toastStore.addToast("Saved.", "info");

    expect(id).toBeGreaterThan(0);
    expect(toastStore.toasts.map((t) => t.message)).toEqual(["Saved."]);
  });

  it("does not add the same message and type twice", () => {
    toastStore.addToast("Saved.", "info");
    const again = toastStore.addToast("Saved.", "info");

    expect(again).toBeUndefined();
    expect(toastStore.toasts).toHaveLength(1);
  });

  it("keeps the same message when its type differs", () => {
    toastStore.addToast("Saved.", "info");
    toastStore.addToast("Saved.", "error");

    expect(toastStore.toasts.map((t) => t.type)).toEqual(["info", "error"]);
  });

  it("removes one toast by id and leaves the rest", () => {
    const first = toastStore.addToast("One", "info");
    toastStore.addToast("Two", "info");

    toastStore.removeToast(first);

    expect(toastStore.toasts.map((t) => t.message)).toEqual(["Two"]);
  });

  it("replaceAll leaves exactly one toast", () => {
    toastStore.addToast("One", "info");
    toastStore.addToast("Two", "info");

    toastStore.replaceAll("Only this", "error");

    expect(toastStore.toasts.map((t) => [t.message, t.type])).toEqual([
      ["Only this", "error"],
    ]);
  });
});
