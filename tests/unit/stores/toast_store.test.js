import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import toastStore from "../../../app/frontend/src/stores/toast_store";

// The messages on screen, as a small stack (#137). Newest first, the
// order the screen shows them. Up to three show at once. An error stays
// until a person closes it; every other message also closes on its own
// timer. A newer message never removes an error.
describe("toastStore", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    toastStore.clearAll();
  });

  afterEach(() => {
    toastStore.clearAll();
    vi.useRealTimers();
  });

  // Every message in the stack, newest first, as [type, words].
  function stack() {
    return toastStore.toasts.map((t) => [t.type, t.message]);
  }

  // The messages the screen shows, newest first, as [type, words].
  function shown() {
    return toastStore.shown.map((t) => [t.type, t.message]);
  }

  it("shows a message and hands back its id", () => {
    const id = toastStore.show("Saved.", "success");

    expect(toastStore.toasts).toEqual([
      { id: id, message: "Saved.", type: "success" },
    ]);
  });

  it("puts a new message on top of the ones on screen", () => {
    toastStore.show("One", "error");
    toastStore.show("Two", "info");
    toastStore.show("Three", "error");

    expect(shown()).toEqual([
      ["error", "Three"],
      ["info", "Two"],
      ["error", "One"],
    ]);
    expect(toastStore.hiddenCount).toBe(0);
  });

  it("never uses an id twice", () => {
    const first = toastStore.show("One", "error");
    toastStore.remove(first);
    const second = toastStore.show("One", "error");

    expect(second).not.toBe(first);
  });

  describe("an error", () => {
    it("stays however long it shows", () => {
      toastStore.show("It failed.", "error");

      vi.advanceTimersByTime(24 * 60 * 60 * 1000);

      expect(stack()).toEqual([["error", "It failed."]]);
    });

    it("is never removed by newer messages", () => {
      toastStore.show("It failed.", "error");
      toastStore.show("One", "info");
      toastStore.show("Two", "warning");
      toastStore.show("Three", "success");
      toastStore.show("Four", "info");

      expect(stack()).toContainEqual(["error", "It failed."]);
    });

    it("goes when a person closes it", () => {
      const id = toastStore.show("It failed.", "error");
      toastStore.show("Something else failed.", "error");

      toastStore.remove(id);

      expect(stack()).toEqual([["error", "Something else failed."]]);
    });
  });

  // Each type that is not an error stays for its own time, and is still
  // there 1 ms before.
  it.each([
    { type: "success", ms: 5000 },
    { type: "info", ms: 5000 },
    { type: "warning", ms: 8000 },
  ])("a $type message closes itself after $ms ms", ({ type, ms }) => {
    toastStore.show("Hello.", type);

    vi.advanceTimersByTime(ms - 1);
    expect(stack()).toEqual([[type, "Hello."]]);

    vi.advanceTimersByTime(1);
    expect(stack()).toEqual([]);
  });

  it("a message's timer removes only that message", () => {
    toastStore.show("It worked.", "info");
    vi.advanceTimersByTime(3000);
    toastStore.show("Careful.", "warning");

    vi.advanceTimersByTime(2000);
    expect(stack()).toEqual([["warning", "Careful."]]);

    vi.advanceTimersByTime(6000);
    expect(stack()).toEqual([]);
  });

  it("a message closed by a person before its timer fires stays closed", () => {
    const id = toastStore.show("It worked.", "info");
    toastStore.remove(id);
    toastStore.show("Something new.", "info");

    vi.advanceTimersByTime(4999);

    expect(stack()).toEqual([["info", "Something new."]]);
  });

  // The stack is drawn under an open dialog (toast.css), so a person
  // cannot see a message while a calendar form, a confirm dialog or a
  // meal's history is open. A message with a timer would close unseen.
  // So no timer runs while a dialog is open, and each message gets its
  // full time again when the dialog closes.
  describe("while a dialog is open", () => {
    afterEach(() => {
      toastStore.setDialogOpen(false);
    });

    it("a message that comes does not close on its timer", () => {
      toastStore.setDialogOpen(true);
      toastStore.show("Cooks saved.", "info");

      vi.advanceTimersByTime(60000);

      expect(stack()).toEqual([["info", "Cooks saved."]]);
      expect(vi.getTimerCount()).toBe(0);
    });

    it("a message that came before it opened stops its timer", () => {
      toastStore.show("Cooks saved.", "info");
      vi.advanceTimersByTime(4000);

      toastStore.setDialogOpen(true);
      vi.advanceTimersByTime(60000);

      expect(stack()).toEqual([["info", "Cooks saved."]]);
      expect(vi.getTimerCount()).toBe(0);
    });

    it("each message that is not an error gets its full time again when the dialog closes", () => {
      toastStore.show("Careful.", "warning");
      vi.advanceTimersByTime(7000);
      toastStore.setDialogOpen(true);
      toastStore.show("Cooks saved.", "info");
      toastStore.show("It failed.", "error");
      vi.advanceTimersByTime(60000);

      toastStore.setDialogOpen(false);
      vi.advanceTimersByTime(4999);
      expect(stack()).toEqual([
        ["error", "It failed."],
        ["info", "Cooks saved."],
        ["warning", "Careful."],
      ]);

      vi.advanceTimersByTime(1);
      expect(stack()).toEqual([
        ["error", "It failed."],
        ["warning", "Careful."],
      ]);

      vi.advanceTimersByTime(3000);
      expect(stack()).toEqual([["error", "It failed."]]);
      expect(vi.getTimerCount()).toBe(0);
    });

    // The page says the dialog is closed each time it looks, not only
    // when it changes. That must not start a message's time over.
    it("hearing again that no dialog is open does not start a timer over", () => {
      toastStore.show("Cooks saved.", "info");
      vi.advanceTimersByTime(4000);

      toastStore.setDialogOpen(false);
      vi.advanceTimersByTime(1000);

      expect(stack()).toEqual([]);
    });

    it("hearing again that a dialog is open starts no timer", () => {
      toastStore.setDialogOpen(true);
      toastStore.show("Cooks saved.", "info");

      toastStore.setDialogOpen(true);

      expect(vi.getTimerCount()).toBe(0);
    });
  });

  describe("more than three messages", () => {
    it("drops the oldest message that is not an error first", () => {
      toastStore.show("Old info", "info");
      toastStore.show("Error A", "error");
      toastStore.show("Newer warning", "warning");
      toastStore.show("Error B", "error");

      expect(stack()).toEqual([
        ["error", "Error B"],
        ["warning", "Newer warning"],
        ["error", "Error A"],
      ]);

      toastStore.show("Newest info", "info");

      expect(stack()).toEqual([
        ["info", "Newest info"],
        ["error", "Error B"],
        ["error", "Error A"],
      ]);
    });

    // A dropped message's timer must not fire later and remove nothing,
    // or worse, a message that took its words.
    it("stops the timer of a dropped message", () => {
      toastStore.show("Old info", "info");
      toastStore.show("Error A", "error");
      toastStore.show("Error B", "error");
      toastStore.show("Error C", "error");
      expect(stack()).not.toContainEqual(["info", "Old info"]);

      expect(vi.getTimerCount()).toBe(0);
    });

    it("keeps every error, and shows the newest three", () => {
      toastStore.show("Error A", "error");
      toastStore.show("Error B", "error");
      toastStore.show("Error C", "error");
      toastStore.show("Error D", "error");
      toastStore.show("Error E", "error");

      expect(toastStore.toasts).toHaveLength(5);
      expect(shown()).toEqual([
        ["error", "Error E"],
        ["error", "Error D"],
        ["error", "Error C"],
      ]);
      expect(toastStore.hiddenCount).toBe(2);
    });

    // The message just shown is what the person just did something
    // about, so it shows even when the three under it are errors.
    it("shows a new message on top of three errors", () => {
      toastStore.show("Error A", "error");
      toastStore.show("Error B", "error");
      toastStore.show("Error C", "error");
      toastStore.show("Cooks saved.", "info");

      expect(shown()).toEqual([
        ["info", "Cooks saved."],
        ["error", "Error C"],
        ["error", "Error B"],
      ]);
      expect(toastStore.hiddenCount).toBe(1);

      vi.advanceTimersByTime(5000);

      expect(shown()).toEqual([
        ["error", "Error C"],
        ["error", "Error B"],
        ["error", "Error A"],
      ]);
      expect(toastStore.hiddenCount).toBe(0);
    });

    it("showAll shows every message", () => {
      ["A", "B", "C", "D", "E"].forEach((name) =>
        toastStore.show(`Error ${name}`, "error"),
      );

      toastStore.showAll();

      expect(shown().map(([, words]) => words)).toEqual([
        "Error E",
        "Error D",
        "Error C",
        "Error B",
        "Error A",
      ]);
      expect(toastStore.hiddenCount).toBe(0);
      expect(toastStore.showingAll).toBe(true);
    });

    it("goes back to three once three or fewer are left", () => {
      const ids = ["A", "B", "C", "D"].map((name) =>
        toastStore.show(`Error ${name}`, "error"),
      );
      toastStore.showAll();

      toastStore.remove(ids[3]);
      expect(toastStore.showingAll).toBe(false);

      toastStore.show("Error E", "error");
      expect(shown().map(([, words]) => words)).toEqual([
        "Error E",
        "Error C",
        "Error B",
      ]);
      expect(toastStore.hiddenCount).toBe(1);
    });

    it("stays showing every message while more than three are left", () => {
      const ids = ["A", "B", "C", "D", "E"].map((name) =>
        toastStore.show(`Error ${name}`, "error"),
      );
      toastStore.showAll();

      toastStore.remove(ids[4]);

      expect(toastStore.showingAll).toBe(true);
      expect(toastStore.shown).toHaveLength(4);
    });
  });

  describe("the same words twice", () => {
    // A new id makes the screen draw a new message, so the person sees
    // it come in again and a screen reader says it again. Otherwise a
    // second failure with the same words, on top already, changes
    // nothing on screen.
    it("moves the message on screen to the top, with a new id", () => {
      const id = toastStore.show("No network.", "error");
      toastStore.show("Something else.", "error");

      const again = toastStore.show("No network.", "error");

      expect(again).not.toBe(id);
      expect(toastStore.toasts.map((t) => t.id)).not.toContain(id);
      expect(toastStore.toasts[0].id).toBe(again);
      expect(stack()).toEqual([
        ["error", "No network."],
        ["error", "Something else."],
      ]);
    });

    it("gives a new id to a message that is on top already", () => {
      const id = toastStore.show("No network.", "error");

      const again = toastStore.show("No network.", "error");

      expect(again).not.toBe(id);
      expect(toastStore.toasts.map((t) => t.id)).toEqual([again]);
    });

    // The old copy's timer must not keep running and remove the new one,
    // or run for nothing.
    it("stops the old copy's timer", () => {
      toastStore.show("Cooks saved.", "info");

      toastStore.show("Cooks saved.", "info");

      expect(vi.getTimerCount()).toBe(1);
    });

    // The number of messages does not change, so a stack the person
    // opened with the "more" line stays open.
    it("keeps every message showing when they all showed", () => {
      ["A", "B", "C", "D"].forEach((name) =>
        toastStore.show(`Error ${name}`, "error"),
      );
      toastStore.showAll();

      toastStore.show("Error A", "error");

      expect(toastStore.showingAll).toBe(true);
      expect(toastStore.shown).toHaveLength(4);
    });

    it("starts the message's timer again", () => {
      toastStore.show("Cooks saved.", "info");
      vi.advanceTimersByTime(4000);

      toastStore.show("Cooks saved.", "info");

      vi.advanceTimersByTime(4999);
      expect(stack()).toEqual([["info", "Cooks saved."]]);
      vi.advanceTimersByTime(1);
      expect(stack()).toEqual([]);
    });

    // An error must stay until a person closes it, whatever shows the
    // same words later.
    it("keeps an error an error, with no timer", () => {
      toastStore.show("Careful.", "error");

      toastStore.show("Careful.", "warning");
      vi.advanceTimersByTime(60000);

      expect(stack()).toEqual([["error", "Careful."]]);
    });

    it("makes a message an error when the new one is an error, and stops its timer", () => {
      toastStore.show("Careful.", "warning");

      toastStore.show("Careful.", "error");
      vi.advanceTimersByTime(60000);

      expect(stack()).toEqual([["error", "Careful."]]);
    });

    it("takes the new type when neither is an error", () => {
      toastStore.show("Careful.", "warning");

      toastStore.show("Careful.", "info");

      expect(stack()).toEqual([["info", "Careful."]]);
    });
  });

  // The message about meals not saved grows when another meal fails:
  // the new words take the place of the old ones (data_store_bills.ts).
  describe("replace", () => {
    it("shows the new words on top, in place of the old message", () => {
      const old = toastStore.show("Meal 1 was not saved.", "error");
      toastStore.show("Something else failed.", "error");

      const id = toastStore.replace(
        old,
        "Meals 1 and 2 were not saved.",
        "error",
      );

      expect(stack()).toEqual([
        ["error", "Meals 1 and 2 were not saved."],
        ["error", "Something else failed."],
      ]);
      expect(id).not.toBe(old);
      expect(toastStore.toasts[0].id).toBe(id);
    });

    // The old message's place frees up first, so nothing else is
    // dropped to make room for the new words.
    it("drops no other message", () => {
      toastStore.show("Cooks saved.", "info");
      const old = toastStore.show("Meal 1 was not saved.", "error");
      toastStore.show("Something else failed.", "error");

      toastStore.replace(old, "Meals 1 and 2 were not saved.", "error");

      expect(stack()).toContainEqual(["info", "Cooks saved."]);
    });

    // A person who tapped the "more" line still sees every message.
    it("keeps every message showing when they all showed", () => {
      const old = toastStore.show("Meal 1 was not saved.", "error");
      ["A", "B", "C"].forEach((name) =>
        toastStore.show(`Error ${name}`, "error"),
      );
      toastStore.showAll();

      toastStore.replace(old, "Meals 1 and 2 were not saved.", "error");

      expect(toastStore.showingAll).toBe(true);
      expect(toastStore.shown).toHaveLength(4);
    });

    it("stops the old message's timer", () => {
      const old = toastStore.show("Careful.", "warning");

      toastStore.replace(old, "It failed.", "error");

      expect(vi.getTimerCount()).toBe(0);
    });
  });

  // The message a screen reader says politely (toast_container.jsx). An
  // error is said at once by its own element, so it is never this one.
  describe("newestNotError", () => {
    it("is null when no message showed", () => {
      expect(toastStore.newestNotError).toBeNull();
    });

    it.each(["success", "info", "warning"])(
      "is the newest %s message",
      (type) => {
        toastStore.show("Older.", "info");
        const id = toastStore.show("Hello.", type);

        expect(toastStore.newestNotError).toEqual({
          id,
          message: "Hello.",
          type,
        });
      },
    );

    it("stays the newest message that is not an error when an error comes after it", () => {
      const id = toastStore.show("Cooks saved.", "info");
      toastStore.show("It failed.", "error");

      expect(toastStore.newestNotError?.id).toBe(id);
    });

    it("is never an error", () => {
      toastStore.show("It failed.", "error");

      expect(toastStore.newestNotError).toBeNull();
    });

    // An older message that is still there was said when it came, so
    // it is not said again when the newer one goes.
    it("is null once that message is gone, even when an older one is still there", () => {
      toastStore.show("Older.", "warning");
      const id = toastStore.show("Newer.", "info");

      toastStore.remove(id);

      expect(toastStore.toasts).toHaveLength(1);
      expect(toastStore.newestNotError).toBeNull();
    });

    it("is null once the same words came again as an error", () => {
      toastStore.show("Careful.", "warning");

      toastStore.show("Careful.", "error");

      expect(toastStore.newestNotError).toBeNull();
    });

    it("is the message again, with its new id, when the same words come again", () => {
      toastStore.show("Cooks saved.", "info");

      const again = toastStore.show("Cooks saved.", "info");

      expect(toastStore.newestNotError?.id).toBe(again);
    });
  });

  it("clearAll removes every message and stops every timer", () => {
    ["A", "B", "C", "D"].forEach((name) =>
      toastStore.show(`Error ${name}`, "error"),
    );
    toastStore.show("Saved.", "info");
    toastStore.showAll();

    toastStore.clearAll();

    expect(toastStore.toasts).toEqual([]);
    expect(toastStore.showingAll).toBe(false);
    expect(vi.getTimerCount()).toBe(0);
  });

  it("remove with an id that is not on screen changes nothing", () => {
    toastStore.show("It failed.", "error");

    toastStore.remove(12345);

    expect(stack()).toEqual([["error", "It failed."]]);
  });
});
