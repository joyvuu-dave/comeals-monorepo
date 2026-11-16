// The app's pages, read from routes.json, the one list the server reads
// too (lib/app_pages.rb, ADR 0016). Add a page there, not here. The
// names below are for the code that needs one pattern by name.
//
// There is no money screen in the SPA. Residents see what they owe in
// ActiveAdmin, through read-only links that ReconciliationMailer emails
// after each settlement. The SPA only collects the inputs: attendance,
// guests, and cooks' bills.
import routes from "./routes.json";

// name -> { path, examples }, in the order routes.json lists them.
export const PAGES = routes.pages;

export const LOGIN_PATH = PAGES.login.path;
export const RESET_PASSWORD_PATH = PAGES.resetPassword.path;
export const CONFIRM_EMAIL_PATH = PAGES.confirmEmail.path;
export const CALENDAR_PATH = PAGES.calendar.path;
// One page, with and without the history box open: the last part is
// optional. MEAL_HISTORY_PATH is the same pattern with that part
// required, to tell whether the box is open.
export const MEAL_EDIT_PATH = PAGES.meal.path;
export const MEAL_HISTORY_PATH = MEAL_EDIT_PATH.replace(/\?$/, "");

// Every address that is not a page. The server answers these with a 404
// and never sends the app, so the app reaches this route only when it
// moves to a bad address on its own.
export const NOT_FOUND_PATH = "*";
