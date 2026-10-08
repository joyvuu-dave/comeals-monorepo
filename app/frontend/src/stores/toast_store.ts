import { makeAutoObservable, observable } from "mobx";

export type ToastType = "success" | "info" | "warning" | "error";

export interface Toast {
  // Never used twice, so the id of a message that is gone matches none
  // on screen.
  id: number;
  message: string;
  type: ToastType;
}

// How long a message that is not an error stays before it closes
// itself. An error has no timer: it stays until a person closes it.
const SHOWN_FOR_MS: Record<Exclude<ToastType, "error">, number> = {
  success: 5000,
  info: 5000,
  warning: 8000,
};

// How many messages show at once. Past this, a line under the stack
// says how many more there are, and shows them when tapped.
export const MOST_SHOWN = 3;

// The messages on screen, as a small stack (#137). Before, the app
// showed one message at a time, and a new one took the place of the
// one on screen. Then a message that a meal's costs were not saved
// could be gone before anyone read it. The rules:
//
// - A new message goes on top. The list is kept newest first, the
//   order the screen shows it.
// - An error stays until a person closes it. A newer message or a
//   timer never removes one. The exception is an error whose cause the
//   page sees fixed: one from a check the page makes itself, such as
//   "Email required." once the email box holds an email, and the errors
//   earlier tries of "Reset your password" got, once a try works. The
//   part of the page that showed such an error removes it.
// - A calendar form's own messages are not here. They show inside the
//   form (use_form_messages.ts), because the stack is drawn under an
//   open dialog.
// - Every other message also closes on its own timer. No timer runs
//   while a dialog is open, because the stack is drawn under it and a
//   person cannot see a message then. When the dialog closes, each
//   message gets its full time again (setDialogOpen).
// - When a new message makes more than MOST_SHOWN, the oldest message
//   that is not an error goes first. The new message itself always
//   stays. So errors can pile up past MOST_SHOWN; the newest
//   MOST_SHOWN show, and the rest wait behind the "more" line.
// - A message with the same words as one in the stack is not added
//   again. The one in the stack moves to the top with a new id, and its
//   timer starts again. The new id makes the screen draw it as a new
//   message: it slides in again, and a screen reader says it again. So
//   a person who tries again and gets the same error can tell the
//   second try failed too. If either of the two is an error, it is an
//   error, so it has no timer.
class ToastStore {
  // Newest first.
  toasts: Toast[] = [];
  // True after the person tapped the "more" line. It goes back to false
  // once MOST_SHOWN or fewer messages are left, so the line shows again
  // the next time there are more.
  showingAll = false;
  // The id of the newest message that is not an error (see
  // newestNotError).
  private newestNotErrorId: number | null = null;
  private nextId = 0;
  private timers = new Map<number, ReturnType<typeof setTimeout>>();
  // True while a dialog is open (see setDialogOpen).
  private dialogOpen = false;

  constructor() {
    makeAutoObservable<ToastStore, "nextId" | "timers" | "dialogOpen">(this, {
      // Shallow: a message is never changed in place, only replaced.
      toasts: observable.shallow,
      nextId: false,
      timers: false,
      // Nothing on screen reads it. It only says whether timers run.
      dialogOpen: false,
    });
  }

  // The messages the screen shows, newest first.
  get shown(): Toast[] {
    return this.showingAll ? this.toasts : this.toasts.slice(0, MOST_SHOWN);
  }

  // How many messages wait behind the "more" line.
  get hiddenCount(): number {
    return this.toasts.length - this.shown.length;
  }

  // The newest message that is not an error, while it is still in the
  // stack, or null. A screen reader says it politely
  // (toast_container.jsx); an error it says at once, from the error's
  // own element. Once this message is gone, an older one still in the
  // stack does not take its place: that one was said when it came.
  get newestNotError(): Toast | null {
    return (
      this.toasts.find((toast) => toast.id === this.newestNotErrorId) ?? null
    );
  }

  // Show a message on top of the stack, and hand back its id.
  show(message: string, type: ToastType): number {
    const same = this.toasts.find((toast) => toast.message === message);
    const toast: Toast = {
      id: ++this.nextId,
      message,
      type: same?.type === "error" ? "error" : type,
    };
    // The copy with the same words goes, and its timer with it. This is
    // not removeWhere: the number of messages stays the same, so a
    // stack the person opened with the "more" line stays open.
    if (same) this.stopTimer(same.id);
    this.toasts = [toast, ...this.toasts.filter((t) => t !== same)];
    if (toast.type !== "error") this.newestNotErrorId = toast.id;
    this.dropOldestThatAreNotErrors();
    this.startTimer(toast);
    return toast.id;
  }

  // Show these words on top, in place of the message with this id, and
  // hand back the new message's id. The old message is taken out first,
  // so no other message is dropped to make room, and a stack the person
  // opened with the "more" line stays open.
  replace(id: number, message: string, type: ToastType): number {
    this.stopTimer(id);
    this.toasts = this.toasts.filter((toast) => toast.id !== id);
    return this.show(message, type);
  }

  // Take away one message: the person closed it, or its timer fired.
  remove(id: number) {
    this.removeWhere((toast) => toast.id === id);
  }

  // The person tapped the "more" line.
  showAll() {
    this.showingAll = true;
  }

  // The page says whether a dialog is open: a calendar form, a confirm
  // dialog, the reset-password form or a meal's history
  // (toast_container.jsx watches for one). The stack is drawn under an
  // open dialog (toast.css), so a person cannot see a message then, and
  // one that closed on its timer would close unseen. So while a dialog
  // is open no timer runs, and when it closes each message that is not
  // an error starts its full time again. Hearing the same thing twice
  // changes nothing, so a message's time does not start over each time
  // the page looks.
  setDialogOpen(open: boolean) {
    if (open === this.dialogOpen) return;
    this.dialogOpen = open;
    if (open) {
      this.timers.forEach((timer) => clearTimeout(timer));
      this.timers.clear();
    } else {
      this.toasts.forEach((toast) => this.startTimer(toast));
    }
  }

  // Take away every message. Only the tests call it, to start each test
  // with no messages: the store is one object for the whole app.
  clearAll() {
    this.removeWhere(() => true);
  }

  private removeWhere(gone: (toast: Toast) => boolean) {
    const kept: Toast[] = [];
    this.toasts.forEach((toast) => {
      if (gone(toast)) {
        this.stopTimer(toast.id);
      } else {
        kept.push(toast);
      }
    });
    this.toasts = kept;
    if (kept.length <= MOST_SHOWN) this.showingAll = false;
  }

  // The new message is at index 0 and is never dropped. The list is
  // newest first, so the search for the oldest starts at the end.
  private dropOldestThatAreNotErrors() {
    let index = this.toasts.length - 1;
    while (this.toasts.length > MOST_SHOWN && index > 0) {
      const toast = this.toasts[index];
      if (toast.type !== "error") {
        this.stopTimer(toast.id);
        this.toasts = this.toasts.filter((t) => t.id !== toast.id);
      }
      index -= 1;
    }
  }

  private startTimer(toast: Toast) {
    if (toast.type === "error" || this.dialogOpen) return;
    this.timers.set(
      toast.id,
      setTimeout(() => this.remove(toast.id), SHOWN_FOR_MS[toast.type]),
    );
  }

  private stopTimer(id: number) {
    clearTimeout(this.timers.get(id));
    this.timers.delete(id);
  }
}

const toastStore = new ToastStore();
export default toastStore;
