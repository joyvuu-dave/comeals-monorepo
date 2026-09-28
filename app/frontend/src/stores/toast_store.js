import { makeAutoObservable } from "mobx";

// The toasts on screen. The app shows one at a time: every caller uses
// replaceAll. ToastContainer removes a toast by id when its timer fires
// or its dismiss button is pressed.
class ToastStore {
  toasts = [];
  _nextId = 0;

  constructor() {
    makeAutoObservable(this);
  }

  removeToast(id) {
    this.toasts = this.toasts.filter(function (t) {
      return t.id !== id;
    });
  }

  clearAll() {
    this.toasts = [];
  }

  replaceAll(message, type) {
    var id = ++this._nextId;
    this.toasts = [{ id: id, message: message, type: type }];
    return id;
  }
}

var toastStore = new ToastStore();
export default toastStore;
