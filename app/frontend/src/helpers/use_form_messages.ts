import { useCallback, useState } from "react";
import handleAxiosError from "./handle_axios_error";
import { newId } from "./new_id";
import type { ToastType } from "../stores/toast_store";

// One message a form shows inside itself.
export interface FormMessage {
  // Never used twice, so React draws a message with new words, or the
  // same words again, as a new element.
  id: string;
  message: string;
  type: ToastType;
}

export interface FormMessages {
  // Newest first, the order the form shows them.
  messages: FormMessage[];
  // What the form calls in place of handleAxiosError when a request
  // fails. The same function on every render.
  showError(error: unknown): void;
  // The person closed this message.
  close(id: string): void;
}

// A calendar form's own messages: the failed requests of the form, shown
// inside the form under its title (form_messages.tsx), not in the stack
// of messages (#137). The stack is drawn under an open dialog, so a
// message there would be hidden while the form is open, which is when
// the person needs it. The messages are the form's state, so they go
// when the form goes, however it goes: the X, Escape, a click outside,
// a save that worked, or the browser's back button.
//
// The rules are the stack's, as far as they fit a form: a newer message
// goes on top, an error stays until a person closes it, and the same
// words again move to the top as a new message, so a person who tries
// again and gets the same error can tell the second try failed too.
// There is no timer and no limit: every message a form gets is about
// the form on screen, and closing the form ends them all.
export default function useFormMessages(): FormMessages {
  const [messages, setMessages] = useState<FormMessage[]>([]);

  const show = useCallback(function (message: string, type: ToastType) {
    setMessages(function (shown) {
      return [
        { id: newId(), message, type },
        ...shown.filter((other) => other.message !== message),
      ];
    });
  }, []);

  const showError = useCallback(
    function (error: unknown) {
      handleAxiosError(error, { show });
    },
    [show],
  );

  const close = useCallback(function (id: string) {
    setMessages(function (shown) {
      return shown.filter((message) => message.id !== id);
    });
  }, []);

  return { messages, showError, close };
}
