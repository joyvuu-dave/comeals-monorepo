# typed: true
# frozen_string_literal: true

# Row labels for the admin schedule grid. Each week row of the cycle is
# named by the real calendar week it currently maps to — "Week of Aug 9
# (this week)" — never by a bare "Week 1". Which slot is the current week
# comes from MealSchedule.weeks_since_epoch; these labels are what keeps
# that arithmetic invisible. An admin only ever reads dates, so a new
# community filling in the grid sees exactly which week each row means,
# and the first generated meal cannot fall in a week the admin did not
# expect.
#
# Rows are always shown in calendar order: this week first, then each
# following week. The stored schedule is in slot order (slot = weeks since
# the epoch, mod the cycle length), and the two orders differ whenever the
# current week is not slot 0 — so each row carries its slot, and the form
# fields are named by slot while the rows are displayed by date.
#
# The grid's add/remove-week JS renames and relabels rows client-side
# (active_admin.js), because changing the cycle length maps every calendar
# week to a different slot. The rows themselves never move — checked days
# stay with the weeks on screen. The JS only picks strings out of the data
# attributes in #schedule_grid_data — every label and note is composed
# here, so the wording lives in one place.
module ScheduleWeekLabelHelper
  # One entry per week row, in calendar order (this week first). Each entry
  # is { slot:, label: } — `slot` is the row's index in the stored schedule,
  # `label` names the calendar week that slot currently maps to. Empty for a
  # zero-length schedule (only reachable through forged params; the form
  # re-render must show the validation errors, not crash).
  # `community` may be the unsaved bootstrap draft, which has no time zone
  # yet, or a re-rendered form carrying a zone name that failed validation;
  # then the app zone is the only zone there is.
  def schedule_week_rows(community, weeks_count)
    return [] if weeks_count.zero?

    sunday = current_sunday(community)
    current = MealSchedule.weeks_since_epoch(sunday) % weeks_count
    Array.new(weeks_count) do |delta|
      { slot: (current + delta) % weeks_count, label: week_label(sunday, delta) }
    end
  end

  # "This pattern repeats every 2 weeks." — under the grid, so a label like
  # "Week of Aug 9" is read as that week and every cycle after it.
  def schedule_repeat_note(weeks_count)
    return 'This pattern repeats every week.' if weeks_count == 1

    "This pattern repeats every #{weeks_count} weeks."
  end

  # Data attributes the grid JS needs to rename and relabel rows when a
  # week is added or removed: the current week's number counted from the
  # epoch, the next six week labels in calendar order (index 0 = this week),
  # and the repeat note for every possible cycle length. All strings are
  # composed here — the JS never builds wording, and formatting dates in the
  # browser would depend on the viewer's timezone.
  def schedule_grid_data(community)
    sunday = current_sunday(community)
    { 'data-epoch-weeks' => MealSchedule.weeks_since_epoch(sunday),
      'data-week-labels' =>
        Array.new(MealSchedule::MAX_WEEKS) { |delta| week_label(sunday, delta) }.to_json,
      'data-repeat-notes' =>
        (1..MealSchedule::MAX_WEEKS).map { |count| schedule_repeat_note(count) }.to_json }
  end

  private

  def current_sunday(community)
    zone = ActiveSupport::TimeZone[community.timezone.to_s] || Time.zone
    Time.current.in_time_zone(zone).to_date.beginning_of_week(:sunday)
  end

  # The one home for the label wording, keyed by how many weeks ahead the
  # row's calendar week is (delta 0 = this week).
  def week_label(sunday, delta)
    label = "Week of #{(sunday + (delta * 7)).strftime('%b %-d')}"
    delta.zero? ? "#{label} (this week)" : label
  end
end
