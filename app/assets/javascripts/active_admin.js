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

  // Meal schedule grid on the community form: add/remove week rows and a
  // live preview. The markup comes from app/admin/community.rb; the dates
  // come from the server (POST /communities/schedule_preview) so the
  // holiday rules and date formatting stay there.
  if ($("#schedule-grid").length) {
    var $scheduleForm = $("#schedule-grid").closest("form");
    var previewTimer = null;

    var scheduleParams = function () {
      // Serialize only the schedule fields — never the whole form. The edit
      // form carries _method=patch, which would turn this POST into a PATCH
      // and miss the route.
      var params = $scheduleForm
        .find(
          '[name^="community[schedule]"], [name="community[meals_per_rotation]"]',
        )
        .serialize();
      var token = $('meta[name="csrf-token"]').attr("content");
      return params + "&authenticity_token=" + encodeURIComponent(token);
    };

    var refreshPreview = function () {
      $.post("/communities/schedule_preview", scheduleParams())
        .done(function (html) {
          $("#schedule-preview").html(html);
        })
        .fail(function (xhr) {
          // 422 carries the validation messages as a fragment; anything
          // else gets a plain sentence instead of an error page.
          $("#schedule-preview").html(
            xhr.status === 422
              ? xhr.responseText
              : "<p>Preview unavailable.</p>",
          );
        });
    };

    // Each row is labeled with the real calendar week it maps to ("Week of
    // Aug 9 (this week)"), mirroring ScheduleWeekLabelHelper. Adding or
    // removing a row changes the cycle length, which remaps every row, so
    // all labels are recomputed here. The dates come preformatted from the
    // server (data-week-labels) — formatting them here would depend on the
    // viewer's timezone.
    var relabelWeeks = function () {
      var $grid = $("#schedule-grid");
      var epochWeeks = parseInt($grid.attr("data-epoch-weeks"), 10);
      var sundays = JSON.parse($grid.attr("data-week-labels"));
      var $rows = $grid.find("tbody tr");
      var count = $rows.length;
      var currentIndex = epochWeeks % count;
      $rows.each(function (rowIndex) {
        var delta = (rowIndex - currentIndex + count) % count;
        var label =
          "Week of " + sundays[delta] + (delta === 0 ? " (this week)" : "");
        $(this).find(".schedule-week-label").contents().last()[0].textContent =
          label;
        $(this)
          .find("input")
          .each(function () {
            this.name = "community[schedule][" + rowIndex + "][]";
            if (this.type === "checkbox") {
              // The day name is always the last word of the old aria-label.
              this.setAttribute(
                "aria-label",
                label + " " + this.getAttribute("aria-label").split(" ").pop(),
              );
            }
          });
      });
      $("#schedule-repeat-note").text(
        count === 1
          ? "This pattern repeats every week."
          : "This pattern repeats every " + count + " weeks.",
      );
      $("#schedule-add-week").prop("disabled", count >= 6);
      $("#schedule-remove-week").prop("disabled", count <= 1);
    };

    $("#schedule-add-week").on("click", function () {
      var $row = $("#schedule-grid tbody tr").last().clone();
      $row.find('input[type="checkbox"]').prop("checked", false);
      $("#schedule-grid tbody").append($row);
      relabelWeeks();
      refreshPreview();
    });

    $("#schedule-remove-week").on("click", function () {
      var $rows = $("#schedule-grid tbody tr");
      if ($rows.length > 1) {
        $rows.last().remove();
      }
      relabelWeeks();
      refreshPreview();
    });

    $scheduleForm.on(
      "change",
      '[name^="community[schedule]"], [name="community[meals_per_rotation]"]',
      refreshPreview,
    );
    $scheduleForm.on(
      "input",
      '[name="community[meals_per_rotation]"]',
      function () {
        clearTimeout(previewTimer);
        previewTimer = setTimeout(refreshPreview, 300);
      },
    );

    relabelWeeks();
    refreshPreview();
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
