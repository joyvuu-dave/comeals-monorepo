# ADR 0006: Draft modals and the discard gate

- **Status:** Accepted
- **Date:** 2026-08-05

## Context

The meal page saves every change the moment it happens. The three modal
forms on the calendar — Guest Room, Common House, and Event — do not.
They hold changes in local state until the user clicks Create or Update.

Before this decision, dismissing one of those modals (a click outside
it, Escape, or the X) threw away any unsaved changes with no warning.
Someone could move a reservation, click away, and believe the move
happened. Nothing told them otherwise.

Two questions had to be answered together, so the answer would only be
decided once:

1. Should these forms become real-time, like the meal page?
2. If not, what should happen when someone dismisses a form with
   unsaved changes?

## Decision

### The app has two write models, on purpose. These forms stay drafts.

**Independent facts save instantly.** On the meal page, each control is
one complete statement — "I am attending" is true or false. Every click
is valid on its own, so it saves on its own.

**Compound facts are drafts with a commit.** A reservation is one fact
made of several fields: a person, a day, a start time, an end time.
While someone edits it, the form passes through states that are wrong
on purpose (the day is changed but the times are not yet). These forms
keep an explicit Create/Update button, and they keep it permanently.
The reasons, so nobody re-opens this:

1. **Mid-edit states are not meant to be saved.** Saving per field
   would persist statements the user never made.
2. **The server checks conflicts.** A half-edited reservation can be
   rejected while the finished edit would have passed.
3. **This is a shared screen with live updates.** Other people watch
   this calendar. The commit makes an edit atomic for them: a
   guest-room move never shows the room briefly free.
4. **Instant saving is only safe with undo everywhere.** The meal page
   gets undo for free — every action is a toggle. These forms would
   need real undo machinery, which costs more than the problem.

### Dismissing a dirty form asks first. A clean form closes silently.

One rule, the same for New and Edit, on all three resources:

- **Clean** (no field differs from what the form started with): a click
  outside, Escape, or the X closes the modal at once. Opening a form
  and deciding not to use it stays free.
- **Dirty** (any field differs): every one of those paths opens one
  question — "Discard your changes?" — with **Keep editing** as the
  safe answer and **Discard** as the deliberate one.
- Create, Update, and Delete close without asking. The form reports
  itself clean before it closes.
- Dirty means _changed by the user_. A value the form was opened with
  (a prefilled day) does not count. A change that is typed and then
  undone also does not count — the form compares values, it does not
  count keystrokes.

New forms follow the same rule as Edit forms so the user learns one
sentence: _if you typed something and try to leave, the app asks._

### The question is a ConfirmModal, not a toast and not an inline bar.

- A **toast** informs; it cannot ask. A decision must block until it is
  answered.
- The inline **ConfirmBar** works by appearing under the control that
  was just tapped. Dismissal has no such place — the trigger can be a
  click anywhere, or a key. And these forms already answer their other
  question (Delete) with `ConfirmModal`; one form should not hold two
  confirm styles.

So the gate uses `ConfirmModal`, extended to follow the same popup
contract as `ConfirmBar` (see `confirm_bar.jsx`):

- The safe button takes focus, so Enter is a no.
- Escape and a click outside the dialog are a no.
- `armMs` guards the confirm button: clicks bounce off until the dialog
  has been open that long, so the second tap of an accidental
  double-tap cannot confirm. The Delete confirms get the same guard —
  they had the same hole.

## How it is built

- `calendar/show.jsx` owns the gate. Every close request runs through
  `handleCloseModal`: clean closes, dirty opens the discard dialog.
- Each form reports its own dirtiness through the `useDirtyReport`
  hook (`helpers/use_dirty_report.js`) and a `setDirty` prop. Edit
  forms compare against the values the fetch hydrated; New forms
  compare against their empty defaults.
- A form that is unmounted reports clean on the way out, so a stale
  flag cannot block the next modal.

## Consequences

- No path loses typed work silently. The worst case is one extra tap.
- The forms keep their Create/Update buttons forever; any future
  request to make them real-time should be answered by pointing here.
- Every new modal form must accept `setDirty` and report through
  `useDirtyReport`, or dismissal will silently discard its changes —
  the exact bug this ADR removes.
