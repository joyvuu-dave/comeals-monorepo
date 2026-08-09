# frozen_string_literal: true

# Row labels for the admin schedule grid. Each week row of the cycle is
# named by the real calendar week it currently maps to — "Week of Aug 9
# (this week)" — never by a bare "Week 1". Which row is the current week
# comes from MealSchedule's epoch arithmetic; these labels are what keeps
# that arithmetic invisible. An admin only ever reads dates, so a new
# community filling in the grid sees exactly which week each row means,
# and the first generated meal cannot land on a surprise week.
#
# The grid's add/remove-week JS recomputes the same labels client-side
# (active_admin.js) from the data attributes in #schedule_grid_data, because
# adding a row changes the cycle length and so remaps every row.
module ScheduleWeekLabelHelper
  # One label per week row, for a cycle of `weeks_count` rows.
  def schedule_week_labels(weeks_count)
    sunday = Time.zone.today.beginning_of_week(:sunday)
    current = ((sunday - MealSchedule::EPOCH).to_i / 7) % weeks_count
    Array.new(weeks_count) do |row|
      delta = (row - current) % weeks_count
      label = "Week of #{(sunday + (delta * 7)).strftime('%b %-d')}"
      delta.zero? ? "#{label} (this week)" : label
    end
  end

  # "This pattern repeats every 2 weeks." — under the grid, so a label like
  # "Week of Aug 9" is read as that week and every cycle after it.
  def schedule_repeat_note(weeks_count)
    return 'This pattern repeats every week.' if weeks_count == 1

    "This pattern repeats every #{weeks_count} weeks."
  end

  # Data attributes the grid JS needs to relabel rows when a week is added
  # or removed: the current week's number counted from the epoch, and the
  # next six Sundays preformatted server-side (formatting dates in the
  # browser would depend on the viewer's timezone).
  def schedule_grid_data
    sunday = Time.zone.today.beginning_of_week(:sunday)
    { 'data-epoch-weeks' => ((sunday - MealSchedule::EPOCH).to_i / 7),
      'data-week-labels' =>
        Array.new(MealSchedule::MAX_WEEKS) { |i| (sunday + (i * 7)).strftime('%b %-d') }.to_json }
  end
end
