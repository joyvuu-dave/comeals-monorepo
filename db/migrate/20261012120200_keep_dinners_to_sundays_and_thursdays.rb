# frozen_string_literal: true

# Makes the meal schedule Sundays and Thursdays, and deletes the upcoming
# Monday and Tuesday meals nobody is on. One of the history fixes the owner
# decided on 2026-10-12, run during the deploy so no person has to do it by
# hand.
#
# The schedule repeated every two weeks: Sunday, Monday and Thursday, then
# Sunday, Tuesday and Thursday. Nobody has eaten a Monday or Tuesday dinner
# since 2021-12-28. Of the 157 that passed since then, 155 had no cook and
# nobody signed up, and admins closed 148 of them by hand. The production
# copy of 2026-10-11 has 27 more on the calendar, through April 2027, with
# no sign-ups and no cooks, in 7 rotations that each keep 8 meals or more.
#
# 1. The schedule. Changed only from exactly the old two-week schedule, so
#    a schedule an admin set since is never overwritten. If it is anything
#    else, this changes nothing at all and says so, because without the new
#    schedule the meals below might be wanted.
# 2. The meals. Every meal on a Monday or Tuesday after the community's
#    today, with no sign-up, no guest and no cook, closed or not. Any other
#    upcoming Monday or Tuesday meal is kept and named in the release log:
#    a person decides about it. So is a meal whose rotation would be left
#    with no meal at all. Past meals are not touched.
#
# Nothing here is money: these meals never had a cost or a sign-up. A
# rotation keeps its other meals, and its bar on the calendar is drawn from
# the meals it has, so it ends at its last Sunday or Thursday. The next
# rotation the nightly job makes (EnsureRotationsJob) starts the day after
# the last meal and follows the new schedule, so no Monday or Tuesday meal
# comes back.
#
# Plain SQL, like migration 20261010130000, for the reasons given there.
# Meal refuses to delete a closed meal (a guard for meals that happened);
# these never happened, so the guard does not apply, and SQL does not run
# it. Each deleted meal gets the delete row a delete through the model
# writes, with no person and no username and this migration in the comment.
# The community's updated_at moves, and a deleted meal moves the row count,
# so the calendar's cache version moves (Community#calendar_cache_version).
#
# The community's today is read the way Community#today reads it: now, in
# the community's own time zone.
#
# down refuses. The schedule can be set back in the admin community form,
# and what each deleted meal held is in its audit row.
class KeepDinnersToSundaysAndThursdays < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  BY = 'Automatic fix (migration 20261012120200).'
  COMMENT = "#{BY} Deleted an upcoming Monday or Tuesday meal nobody was on, when the meal schedule became " \
            'Sundays and Thursdays.'.freeze
  OLD_SCHEDULE = [[0, 1, 4], [0, 2, 4]].freeze
  NEW_SCHEDULE = [[0, 4]].freeze
  MONDAY_OR_TUESDAY = [1, 2].freeze
  ATTEMPTS = 5

  Candidate = Struct.new(:id, :date, :rotation_id, :someone)

  def up
    with_retry { connection.transaction { keep_to_sundays_and_thursdays } }.each { |line| say line }
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          'Migration 20261012120200 made the meal schedule Sundays and Thursdays and deleted upcoming Monday and ' \
          'Tuesday meals nobody was on. Set the schedule back in the admin community form. What each deleted ' \
          "meal held is in the audit rows whose comment starts with #{BY.inspect}."
  end

  private

  # Returns the lines to print.
  def keep_to_sundays_and_thursdays
    community = connection.select_one('SELECT id, schedule, timezone FROM communities ORDER BY id LIMIT 1 FOR UPDATE')
    return ['No community: nothing to do.'] if community.nil?

    schedule = JSON.parse(community['schedule'])
    return [left_schedule(schedule)] unless [OLD_SCHEDULE, NEW_SCHEDULE].include?(schedule)

    lines = [set_schedule(Integer(community['id']), schedule)]
    lines + delete_meals(Time.current.in_time_zone(community['timezone']).to_date)
  end

  def left_schedule(schedule)
    "Left the meal schedule as it is: it is #{schedule.inspect}, not #{OLD_SCHEDULE.inspect}, so an admin " \
      'changed it. Deleted no meals.'
  end

  def set_schedule(community_id, schedule)
    return 'The meal schedule is already Sundays and Thursdays.' if schedule == NEW_SCHEDULE

    connection.execute(<<~SQL.squish)
      UPDATE communities SET schedule = #{connection.quote(NEW_SCHEDULE.to_json)}::jsonb,
                             updated_at = #{connection.quote(Time.current.utc)}
      WHERE id = #{community_id}
    SQL
    'Set the meal schedule to Sundays and Thursdays.'
  end

  # Returns the lines to print.
  def delete_meals(today)
    candidates = upcoming_mondays_and_tuesdays(today)
    busy, empty = candidates.partition(&:someone)
    lonely, deleted = would_empty_a_rotation(empty)
    write_delete(deleted)
    [report('Deleted %d upcoming Monday and Tuesday meal(s) with nobody on them', deleted),
     report('Kept %d upcoming Monday or Tuesday meal(s) because someone is on them', busy),
     report('Kept %d meal(s) that would leave a rotation empty', lonely)].compact
  end

  # Locked in id order, the order every meal write uses.
  def upcoming_mondays_and_tuesdays(today)
    connection.select_rows(<<~SQL.squish).map { |row| Candidate.new(row[0], row[1].to_date, row[2], yes?(row[3])) }
      SELECT meals.id, meals.date, meals.rotation_id,
             EXISTS (SELECT 1 FROM meal_residents WHERE meal_residents.meal_id = meals.id)
               OR EXISTS (SELECT 1 FROM guests WHERE guests.meal_id = meals.id)
               OR EXISTS (SELECT 1 FROM bills WHERE bills.meal_id = meals.id)
               OR meals.reconciliation_id IS NOT NULL
      FROM meals
      WHERE meals.date > #{connection.quote(today)}
        AND EXTRACT(DOW FROM meals.date) IN (#{MONDAY_OR_TUESDAY.join(', ')})
      ORDER BY meals.id
      FOR UPDATE
    SQL
  end

  # Returns [kept, to delete]: a rotation must keep at least one meal.
  def would_empty_a_rotation(meals)
    return [[], []] if meals.empty?

    sizes = connection.select_rows(<<~SQL.squish).to_h { |id, count| [Integer(id), Integer(count)] }
      SELECT rotation_id, COUNT(*) FROM meals
      WHERE rotation_id IN (#{meals.map { |meal| Integer(meal.rotation_id) }.uniq.join(', ')})
      GROUP BY rotation_id
    SQL
    meals.partition do |meal|
      sizes.fetch(Integer(meal.rotation_id)) == meals.count { |other| other.rotation_id == meal.rotation_id }
    end
  end

  def write_delete(meals)
    return if meals.empty?

    ids = meals.map { |meal| Integer(meal.id) }.join(', ')
    connection.execute(<<~SQL.squish)
      INSERT INTO audits (auditable_type, auditable_id, associated_type, associated_id, action,
                          audited_changes, version, comment, username, request_uuid, created_at)
      SELECT 'Meal', meals.id, NULL, NULL, 'destroy', to_jsonb(meals.*) - 'id' - 'created_at' - 'updated_at',
             COALESCE((SELECT MAX(audits.version) FROM audits
                       WHERE audits.auditable_type = 'Meal' AND audits.auditable_id = meals.id), 0) + 1,
             #{connection.quote(COMMENT)}, NULL, #{connection.quote(SecureRandom.uuid)},
             #{connection.quote(Time.current.utc)}
      FROM meals WHERE meals.id IN (#{ids})
      ORDER BY meals.id
    SQL
    connection.execute("DELETE FROM meals WHERE id IN (#{ids})")
  end

  # "<what>: date, date." or nil when there are none.
  def report(what, meals)
    return nil if meals.empty?

    "#{format(what, meals.size)}: #{meals.map(&:date).sort.join(', ')}."
  end

  def with_retry
    attempt = 0
    begin
      attempt += 1
      yield
    rescue ActiveRecord::TransactionRollbackError, ActiveRecord::LockWaitTimeout
      raise if attempt >= ATTEMPTS || connection.transaction_open?

      say "PostgreSQL refused this for a conflict with another write. Trying again (#{attempt + 1} of #{ATTEMPTS}).",
          true
      sleep(0.1 * (2**attempt))
      retry
    end
  end

  # PostgreSQL's true and false, as the connection hands them back.
  def yes?(value)
    ActiveModel::Type::Boolean.new.cast(value) == true
  end
end
