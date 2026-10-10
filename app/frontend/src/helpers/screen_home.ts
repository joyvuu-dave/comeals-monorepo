import dayjs from "dayjs";
import { matchPath } from "react-router";

import { CALENDAR_PATH } from "../routes";

// Where the shared screen goes by itself (components/app/back_to_today.tsx).
// Every day here is a "YYYY-MM-DD" string, the community's day.

// How long the screen waits with nobody using it before it goes back to
// today's calendar.
export const IDLE_MS = 5 * 60 * 1000;

interface CalendarParams {
  date?: string;
  modal?: string;
}

// The calendar's address, or null for any other page.
function calendarParams(pathname: string): CalendarParams | null {
  const match = matchPath(CALENDAR_PATH, pathname);
  return match === null ? null : match.params;
}

// What the open calendar form holds that would be lost if it closed.
// The form reports both (calendar/show.jsx), and both are false when no
// form is open.
export interface OpenForm {
  // Changes a person typed: the flag the discard gate reads (ADR 0006).
  // Each form compares its fields with the values it opened with, so a
  // change typed and then undone does not count.
  dirty: boolean;
  // An error message of the form's own, shown inside the form
  // (use_form_messages.ts). It goes when the form closes, and an error
  // stays until a person closes it (#137).
  errorShown: boolean;
}

// True when a calendar form is open that the screen must not close by
// itself. Then nothing here closes it or moves the calendar under it.
//
// - A form with typed changes. ADR 0006: a typed draft is never dropped
//   without the question "Discard your changes?", and on an idle screen
//   nobody is there to answer it.
// - A form that shows an error of its own: a refused Delete, an Edit
//   form whose record could not be loaded (#115), a refused Create. The
//   error would go with the form, unread.
//
// A form with nothing typed and no error, and a dialog that only shows
// something (a rotation's list of meals), have nothing to lose. They
// close the way the screen leaves a calendar with no dialog open.
function keepsForm(calendar: CalendarParams, form: OpenForm): boolean {
  return calendar.modal !== undefined && (form.dirty || form.errorShown);
}

// True when both days are in one month of one year. A day that is not a
// date is in no month.
function sameMonth(day: string | undefined, other: string): boolean {
  const month = dayjs(day);
  return month.isValid() && month.format("YYYY-MM") === other.slice(0, 7);
}

function calendarOf(day: string): string {
  return `/calendar/all/${day}/`;
}

// Where the screen goes when nobody has used it for IDLE_MS, or null to
// stay. Home is today's calendar. A calendar that already shows today's
// month with no dialog open stays as it is, and so does a calendar
// whose form holds typed changes or shows an error (keepsForm). Any
// other dialog is closed, on any month: a form with nothing typed and
// no error, and a rotation's dialog. Signed out, there is no calendar,
// and every page stays: the login page is home already ("/" also sends
// a signed-in screen to today's calendar by itself), and a reset link's
// page holds the new password someone may be typing.
export function pathAfterIdle(
  pathname: string,
  today: string,
  signedIn: boolean,
  form: OpenForm,
): string | null {
  if (!signedIn || pathname === "/") return null;
  const home = calendarOf(today);
  const calendar = calendarParams(pathname);
  if (calendar === null) return home;
  if (keepsForm(calendar, form)) return null;
  if (calendar.modal === undefined && sameMonth(calendar.date, today)) {
    return null;
  }
  return home;
}

// What the idle timer knows about the screen besides its address.
export interface ScreenState {
  // The page crashed, and shows "Something went wrong" (ErrorBoundary).
  crashed: boolean;
  // A newer build is on the server than the code running here
  // (VersionBanner).
  newVersion: boolean;
  // An error message is in the stack of messages. A form's own error is
  // in form.
  errorShown: boolean;
  // What the open calendar form holds (keepsForm).
  form: OpenForm;
}

// The page to load from the server when nobody has used the screen for
// IDLE_MS, or null to load nothing. Then pathAfterIdle says where to
// move inside the app. Two things need a page load, because a move
// inside the app fixes neither:
//
// - The page crashed. The error page stays when the address changes.
//   Nothing is lost: the error page took the place of every form, and
//   each form reported nothing typed and no error as it went
//   (use_dirty_report.js, use_form_messages.ts). So form is not read
//   here. Still set, it could only be a flag the broken store failed to
//   clear, and the error page would then stay for good. Home is today's
//   calendar, or the login page when signed out.
// - A new version is out. Without a load, the screen runs the old code
//   until someone taps Refresh, and the old code may send requests the
//   new server reads differently. Not while a form holds typed changes
//   (ADR 0006) or shows an error of its own (keepsForm); any other form
//   goes with the load. Not when signed out either: signing in loads
//   the page again by itself, and the page a reset link opens holds the
//   new password someone may be typing.
//
// Never while an error message is in the stack. A page load takes every
// message away, and an error stays until a person closes it (#137).
// Closing it is a tap, which starts the five minutes again. A message
// that is not an error closes by itself after a few seconds, so it does
// not hold the page.
export function pathToLoadAfterIdle(
  pathname: string,
  today: string,
  signedIn: boolean,
  screen: ScreenState,
): string | null {
  if (screen.errorShown) return null;
  if (screen.crashed) return signedIn ? calendarOf(today) : "/";
  if (!screen.newVersion || !signedIn) return null;
  const calendar = calendarParams(pathname);
  if (calendar !== null && keepsForm(calendar, screen.form)) return null;
  return calendarOf(today);
}

// Where the calendar goes when the community's day changes (midnight, or
// a wake from sleep, or a new zone), or null to stay. A calendar that
// showed the old day's month moves to the new day's month, unless its
// form holds typed changes or shows an error (keepsForm). Any other
// form closes with the move. A calendar someone paged to another month
// stays there, with its dialog.
export function pathAfterNewDay(
  pathname: string,
  oldToday: string,
  newToday: string,
  form: OpenForm,
): string | null {
  const calendar = calendarParams(pathname);
  if (calendar === null || keepsForm(calendar, form)) return null;
  if (!sameMonth(calendar.date, oldToday)) return null;
  if (sameMonth(newToday, oldToday)) return null;
  return calendarOf(newToday);
}
