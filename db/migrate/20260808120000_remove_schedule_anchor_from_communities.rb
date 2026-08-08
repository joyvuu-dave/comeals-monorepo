# frozen_string_literal: true

# Remove schedule_anchor_date; the cycle phase becomes fixed arithmetic (#53).
#
# The anchor date named which calendar week was week 1 of the cycle. But the
# form's date field read as a start date ("starts the week of"), and a start
# date is not what it was — it never delayed or gated anything. The real
# choice it carried, "which week of the cycle is this calendar week", can
# already be expressed by the grid itself: moving a day to a different week
# row shifts it by a week. So the anchor is redundant with the grid, and it
# goes.
#
# In its place, MealSchedule::EPOCH (a fixed Sunday, 2000-01-02) names week 1
# for everyone, forever. To keep every community's generated dates exactly
# the same, this migration rotates each stored schedule's rows into epoch
# phase before dropping the column.
#
# The arithmetic: with k weeks, the old model put date d in row
# ((d - anchor)/7) % k and the new model puts it in ((d - EPOCH)/7) % k,
# which is (old row + offset) % k where offset = ((anchor - EPOCH)/7) % k.
# So new row j must hold what old row (j - offset) % k held.
class RemoveScheduleAnchorFromCommunities < ActiveRecord::Migration[8.1]
  # A literal, not MealSchedule::EPOCH: a migration must stay correct as
  # written even if the app code around it changes. It matches the model
  # constant, and both say the value must never change.
  EPOCH = Date.new(2000, 1, 2)

  def up
    select_all('SELECT id, schedule, schedule_anchor_date FROM communities').each do |row|
      weeks = JSON.parse(row['schedule'])
      anchor = Date.parse(row['schedule_anchor_date'].to_s)
      k = weeks.length
      offset = ((anchor - EPOCH).to_i / 7) % k
      rotated = Array.new(k) { |j| weeks[(j - offset) % k] }
      execute("UPDATE communities SET schedule = #{connection.quote(rotated.to_json)} " \
              "WHERE id = #{Integer(row['id'])}")
    end

    remove_check_constraint :communities, name: 'communities_schedule_anchor_is_sunday'
    remove_column :communities, :schedule_anchor_date
  end

  def down
    # Setting every anchor to the epoch itself makes the old arithmetic
    # produce the same dates as the new — offset 0, so no row un-rotation
    # is needed.
    add_column :communities, :schedule_anchor_date, :date
    execute("UPDATE communities SET schedule_anchor_date = '#{EPOCH}'")
    change_column_null :communities, :schedule_anchor_date, false
    add_check_constraint :communities, 'EXTRACT(dow FROM schedule_anchor_date) = 0',
                         name: 'communities_schedule_anchor_is_sunday'
  end
end
