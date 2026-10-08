import { useEffect, useRef } from "react";
import type { FormMessages as Messages } from "../../helpers/use_form_messages";

type Props = Pick<Messages, "messages" | "close">;

// A form's own messages (use_form_messages.ts), drawn inside the form
// under its title, newest on top (#137). They look like the messages in
// the stack, so a person reads them the same way.
//
// Each one is its own alert, so a screen reader says it as soon as it
// comes. The form is inside the dialog, which is the part of the page a
// screen reader reads while the dialog is open.
//
// On a phone the form is taller than the screen, and the person tapped
// Create or Update at the bottom of it. So the form scrolls to show the
// messages whenever the one on top changes: a new message, or the same
// words again.
function FormMessages({ messages, close }: Props) {
  const boxRef = useRef<HTMLDivElement>(null);
  const newestId = messages[0]?.id;

  useEffect(
    function () {
      if (newestId === undefined) return;
      boxRef.current?.scrollIntoView({ block: "nearest" });
    },
    [newestId],
  );

  if (messages.length === 0) return null;

  return (
    <div className="form-messages" ref={boxRef}>
      {messages.map(function (message) {
        return (
          <div
            key={message.id}
            className={"form-message form-message--" + message.type}
            role="alert"
            aria-live="assertive"
          >
            <span className="form-message__text">{message.message}</span>
            <button
              type="button"
              className="form-message__dismiss"
              onClick={() => close(message.id)}
              aria-label="Dismiss"
            >
              ✕
            </button>
          </div>
        );
      })}
    </div>
  );
}

export default FormMessages;
