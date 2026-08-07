//= require active_admin/base

// Behavior only. Anything that is really a style lives in
// active_admin.scss, and date formatting is done by the server
// (config/locales/en.yml, date.formats.admin) — the old approach of
// reparsing rendered dates here depended on the viewer's timezone.
$(function () {
  // Bring the name field into focus when adding a new unit or resident
  if (window.location.pathname === "/units/new") {
    $("#unit_name").focus();
  }
  if (window.location.pathname === "/residents/new") {
    $("#resident_name").focus();
  }

  // Clear bill amount if it's 0, so the cook's real cost must be typed
  if ($("#bill_amount_decimal").val() === "0.0") {
    $("#bill_amount_decimal").val("");
  }

  // Default the remember-me checkbox to checked
  $("#admin_user_remember_me").prop("checked", true);

  // There is exactly one community; the plural page title reads wrong
  if ($("#page_title").html() === "Communities") {
    $("#page_title").html("Community");
  }

  // Say which login this is, and point residents at theirs. The
  // resident app lives on this same host minus the admin subdomain —
  // true in production (comeals.com) and in dev (lvh.me:3000).
  if (window.location.pathname === "/login") {
    var userUrl =
      window.location.protocol +
      "//" +
      window.location.host.replace(/^admin\./, "");
    $("body").prepend(
      '<div class="admin-login-banner">' +
        "<h3>Admin Login</h3>" +
        '<a href="' +
        userUrl +
        '">Looking for the resident login?</a>' +
        "</div>",
    );
  }
});
