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

  // Default the remember-me checkbox to checked
  $("#admin_user_remember_me").prop("checked", true);

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

    // Rows never move: they are in calendar order (this week first), adding
    // a week appends an empty bottom row (the furthest-future week), and
    // removing takes the bottom row away. The checked days you see stay
    // with the calendar weeks you see. What changes under an add or remove
    // is the naming: the stored cycle is in slot order (slot = weeks since
    // the epoch, mod the cycle length), and a new length maps every week to
    // a different slot — so every row's fields are renamed to the slot its
    // calendar week maps to now. Every string comes finished from the
    // server (ScheduleWeekLabelHelper via the data attributes): this code
    // only picks by index, never composes wording, so the words cannot
    // drift from the Ruby copy — and formatting dates here would depend on
    // the viewer's timezone.
    var arrangeWeeks = function () {
      var $grid = $("#schedule-grid");
      var epochWeeks = parseInt($grid.attr("data-epoch-weeks"), 10);
      var weekLabels = JSON.parse($grid.attr("data-week-labels"));
      var repeatNotes = JSON.parse($grid.attr("data-repeat-notes"));
      var $rows = $grid.find("tbody tr");
      var count = $rows.length;
      var currentIndex = epochWeeks % count;
      $rows.each(function (rowIndex) {
        var label = weekLabels[rowIndex];
        var slot = (currentIndex + rowIndex) % count;
        $(this).find(".schedule-week-label").contents().last()[0].textContent =
          label;
        $(this)
          .find("input")
          .each(function () {
            this.name = "community[schedule][" + slot + "][]";
            if (this.type === "checkbox") {
              // The day name is always the last word of the old aria-label.
              this.setAttribute(
                "aria-label",
                label + " " + this.getAttribute("aria-label").split(" ").pop(),
              );
            }
          });
      });
      $("#schedule-repeat-note").text(repeatNotes[count - 1]);
      $("#schedule-add-week").prop("disabled", count >= 6);
      $("#schedule-remove-week").prop("disabled", count <= 1);
    };

    $("#schedule-add-week").on("click", function () {
      var $row = $("#schedule-grid tbody tr").last().clone();
      $row.find('input[type="checkbox"]').prop("checked", false);
      $("#schedule-grid tbody").append($row);
      arrangeWeeks();
      refreshPreview();
    });

    $("#schedule-remove-week").on("click", function () {
      var $rows = $("#schedule-grid tbody tr");
      if ($rows.length > 1) {
        $rows.last().remove();
      }
      arrangeWeeks();
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

    arrangeWeeks();
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
