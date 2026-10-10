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

// The calendar's dialogs that only show something and hold nothing a
// person typed. A rotation's dialog shows a list of meals.
const VIEW_ONLY_DIALOGS = ["rotations"];

// A calendar form is open: Guest Room, Common House or Event, New or
// Edit. ADR 0006: a form is a draft until Create or Update, so nothing
// here closes it or moves the calendar under it. Every dialog that is
// not on the view-only list counts as a form, so a form added later is
// kept safe without a change here.
function formOpen(calendar: CalendarParams): boolean {
  return (
    calendar.modal !== undefined && !VIEW_ONLY_DIALOGS.includes(calendar.modal)
  );
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
// month with no dialog open stays as it is, and so does a calendar with
// a form open. A rotation's dialog is closed, on any month. Signed out,
// there is no calendar, and every page stays: the login page is home
// already ("/" also sends a signed-in screen to today's calendar by
// itself), and a reset link's page holds the new password someone may
// be typing.
export function pathAfterIdle(
  pathname: string,
  today: string,
  signedIn: boolean,
): string | null {
  if (!signedIn || pathname === "/") return null;
  const home = calendarOf(today);
  const calendar = calendarParams(pathname);
  if (calendar === null) return home;
  if (formOpen(calendar)) return null;
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
  // An error message is on screen.
  errorShown: boolean;
}

// The page to load from the server when nobody has used the screen for
// IDLE_MS, or null to load nothing. Then pathAfterIdle says where to
// move inside the app. Two things need a page load, because a move
// inside the app fixes neither:
//
// - The page crashed. The error page stays when the address changes.
//   Nothing typed is lost: the error page took the place of every form.
//   Home is today's calendar, or the login page when signed out.
// - A new version is out. Without a load, the screen runs the old code
//   until someone taps Refresh, and the old code may send requests the
//   new server reads differently. Not while a form is open (ADR 0006).
//   Not when signed out either: signing in loads the page again by
//   itself, and the page a reset link opens holds the new password
//   someone may be typing.
//
// Never while an error message is on screen. A page load takes every
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
  if (calendar !== null && formOpen(calendar)) return null;
  return calendarOf(today);
}

// Where the calendar goes when the community's day changes (midnight, or
// a wake from sleep, or a new zone), or null to stay. A calendar that
// showed the old day's month moves to the new day's month, unless a form
// is open. A calendar someone paged to another month stays there.
export function pathAfterNewDay(
  pathname: string,
  oldToday: string,
  newToday: string,
): string | null {
  const calendar = calendarParams(pathname);
  if (calendar === null || formOpen(calendar)) return null;
  if (!sameMonth(calendar.date, oldToday)) return null;
  if (sameMonth(newToday, oldToday)) return null;
  return calendarOf(newToday);
}
