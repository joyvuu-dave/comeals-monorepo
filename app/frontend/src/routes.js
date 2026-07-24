// The app's route patterns, in the order index.jsx mounts them. They
// live in one place so unit tests can pin route matching and param
// extraction against the exact strings the app uses — an upgrade of
// react-router that changes matching behavior then fails a small test
// instead of a page.
export const CALENDAR_PATH = "/calendar/:type/:date/:modal?/:view?/:id?";
export const MEAL_EDIT_PATH = "/meals/:id/edit/*";
export const LOGIN_PATH = "/:modal?/:token?";

// Matched by the descendant <Routes> inside DateBox against the
// pathname left over after MEAL_EDIT_PATH's splat.
export const MEAL_HISTORY_PATH = "history/*";
