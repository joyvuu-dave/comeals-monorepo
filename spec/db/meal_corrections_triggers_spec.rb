# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261010125951_create_meal_corrections.rb')

# The database's own rules for corrections to settled dinners (ADR 0011
# rule 6), migrations 20261010125951 and 20261010125952. Each statement
# here is raw SQL, the way psql or update_all writes, so no model rule
# runs: only the triggers and the CHECKs stand between it and the table.
RSpec.describe 'meal correction triggers' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:latest) { Reconciliation.latest_cutoff(community.today) }
  let(:cook) { create(:resident, community: community, unit: unit) }
  let(:eater) { create(:resident, community: community, unit: unit) }
  let(:admin) { create(:admin_user, community: community, superuser: true) }
  let(:connection) { ActiveRecord::Base.connection }
  # Settled by the first settlement; `carrier` is a later one.
  let!(:meal) { dinner(latest - 1).tap { settle!(cutoff: latest - 1) }.reload }
  let!(:carrier) { dinner(latest).then { settle!(cutoff: latest) } }

  def dinner(date)
    create(:meal, community: community, date: date).tap do |meal|
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
      create(:meal_resident, meal: meal, resident: eater, community: community)
    end
  end

  # A setting for the rest of the test's transaction, the way the app
  # sets it (set_config(..., true)).
  def set(name, value)
    connection.execute(ActiveRecord::Base.sanitize_sql_array(['SELECT set_config(?, ?, true)', name, value]))
  end

  def sql(statement)
    connection.select_value(statement)
  end

  # Runs in a savepoint, so the refusal does not end the test's
  # transaction.
  def expect_refused(statement, message)
    expect { ActiveRecord::Base.transaction(requires_new: true) { connection.execute(statement) } }
      .to raise_error(ActiveRecord::StatementInvalid, message)
  end

  def insert_correction(meal_id: meal.id, reconciliation_id: 'NULL')
    'INSERT INTO meal_corrections (meal_id, admin_user_id, reason, reconciliation_id, created_at, updated_at) ' \
      "VALUES (#{meal_id}, #{admin.id}, 'A reason', #{reconciliation_id}, now(), now()) RETURNING id"
  end

  # A correction of `meal`, written the way MealCorrecting writes it.
  def correction_id
    @correction_id ||= begin
      set('comeals.correcting', meal.id.to_s)
      id = sql(insert_correction)
      sql('INSERT INTO meal_correction_lines (meal_correction_id, resident_id, amount, created_at, updated_at) ' \
          "VALUES (#{id}, #{cook.id}, -10, now(), now()), (#{id}, #{eater.id}, 10, now(), now()) RETURNING id")
      set('comeals.correcting', '')
      id
    end
  end

  describe 'adding a correction' do
    it 'is let through for the settled dinner being corrected' do
      expect(correction_id).to be_present
      expect(MealCorrectionLine.where(meal_correction_id: correction_id).sum(:amount)).to eq(0)
    end

    it 'is refused for a dinner that is not being corrected' do
      expect_refused(insert_correction, /meal #{meal.id} is not being corrected/)
      set('comeals.correcting', (meal.id + 1000).to_s)
      expect_refused(insert_correction, /not being corrected/)
    end

    it 'is refused for an open dinner' do
      open = create(:meal, community: community, date: latest + 1)
      set('comeals.correcting', open.id.to_s)

      expect_refused(insert_correction(meal_id: open.id), /meal #{open.id} is not settled/)
    end

    it 'is refused already carried by a settlement' do
      set('comeals.correcting', meal.id.to_s)

      expect_refused(insert_correction(reconciliation_id: carrier.id), /carried by no settlement yet/)
    end
  end

  describe 'its lines' do
    it 'are refused when the dinner is not being corrected' do
      expect_refused('INSERT INTO meal_correction_lines (meal_correction_id, resident_id, amount, created_at, ' \
                     "updated_at) VALUES (#{correction_id}, #{eater.id}, 5, now(), now())",
                     /written only by MealCorrecting/)
    end

    it 'must add up to zero' do
      set('comeals.correcting', meal.id.to_s)
      id = sql(insert_correction)

      expect_refused('INSERT INTO meal_correction_lines (meal_correction_id, resident_id, amount, created_at, ' \
                     "updated_at) VALUES (#{id}, #{cook.id}, -10, now(), now()), (#{id}, #{eater.id}, 9, now(), now())",
                     /its lines sum to -1/)
    end

    it 'are never zero' do
      set('comeals.correcting', meal.id.to_s)
      id = sql(insert_correction)

      expect_refused('INSERT INTO meal_correction_lines (meal_correction_id, resident_id, amount, created_at, ' \
                     "updated_at) VALUES (#{id}, #{cook.id}, 0, now(), now())", /meal_correction_lines_not_zero/)
    end

    it 'are refused once a settlement carries the correction' do
      set('comeals.settling', carrier.id.to_s)
      connection.execute("UPDATE meal_corrections SET reconciliation_id = #{carrier.id} WHERE id = #{correction_id}")
      set('comeals.settling', '')
      set('comeals.correcting', meal.id.to_s)

      expect_refused('INSERT INTO meal_correction_lines (meal_correction_id, resident_id, amount, created_at, ' \
                     "updated_at) VALUES (#{correction_id}, #{create(:resident,
                                                                     community: community).id}, 1, now(), now())",
                     /written only by MealCorrecting/)
    end

    it 'cannot be changed or deleted' do
      expect_refused("UPDATE meal_correction_lines SET amount = -11 WHERE meal_correction_id = #{correction_id}",
                     /a correction line is a record/)
      expect_refused("DELETE FROM meal_correction_lines WHERE meal_correction_id = #{correction_id}",
                     /a correction line is a record/)
    end
  end

  describe 'a correction once written' do
    it 'is claimed once, by a later settlement, while that settlement is settling' do
      set('comeals.settling', carrier.id.to_s)
      connection.execute("UPDATE meal_corrections SET reconciliation_id = #{carrier.id}, updated_at = now() " \
                         "WHERE id = #{correction_id}")

      expect(sql("SELECT reconciliation_id FROM meal_corrections WHERE id = #{correction_id}")).to eq(carrier.id)
      expect_refused("UPDATE meal_corrections SET reconciliation_id = NULL WHERE id = #{correction_id}",
                     /a correction is a record/)
    end

    it 'is not claimed by a settlement that is not settling' do
      expect_refused("UPDATE meal_corrections SET reconciliation_id = #{carrier.id} WHERE id = #{correction_id}",
                     /a correction is a record/)
    end

    it 'is not claimed by the dinner\'s own settlement' do
      own = meal.reconciliation_id
      set('comeals.settling', own.to_s)

      expect_refused("UPDATE meal_corrections SET reconciliation_id = #{own} WHERE id = #{correction_id}",
                     /a correction is a record/)
    end

    it 'cannot have its reason or edits changed, even by the claim' do
      set('comeals.settling', carrier.id.to_s)

      expect_refused("UPDATE meal_corrections SET reconciliation_id = #{carrier.id}, reason = 'Another' " \
                     "WHERE id = #{correction_id}", /a correction is a record/)
      expect_refused("UPDATE meal_corrections SET edits = '[1]' WHERE id = #{correction_id}",
                     /a correction is a record/)
    end

    it 'cannot be deleted, except with the repair bypass' do
      expect_refused("DELETE FROM meal_corrections WHERE id = #{correction_id}", /a correction is a record/)

      set('comeals.allow_settled_writes', 'on')
      connection.execute("DELETE FROM meal_correction_lines WHERE meal_correction_id = #{correction_id}")
      connection.execute("DELETE FROM meal_corrections WHERE id = #{correction_id}")
      expect(MealCorrection.exists?(correction_id)).to be(false)
    end
  end

  # 20261010125952: the dinner being corrected, and only it.
  describe 'the rows of a settled dinner' do
    let(:other) { create(:resident, community: community, unit: unit) }
    let(:carried_meal) { carrier.meals.sole }

    def add_eater(meal_id)
      'INSERT INTO meal_residents (meal_id, resident_id, community_id, multiplier, late, vegetarian, created_at, ' \
        "updated_at) VALUES (#{meal_id}, #{other.id}, #{community.id}, 2, false, false, now(), now())"
    end

    it 'can be written while the dinner is being corrected' do
      set('comeals.correcting', meal.id.to_s)
      connection.execute(add_eater(meal.id))

      expect(MealResident.where(meal_id: meal.id).count).to eq(2)
    end

    it 'cannot be written for another settled dinner meanwhile' do
      set('comeals.correcting', meal.id.to_s)

      expect_refused(add_eater(carried_meal.id), /meal #{carried_meal.id} is reconciled/)
    end

    it 'cannot be moved from the dinner being corrected onto another settled dinner, or back' do
      set('comeals.correcting', meal.id.to_s)
      row = MealResident.find_by!(meal_id: meal.id)
      away = MealResident.find_by!(meal_id: carried_meal.id)

      expect_refused("UPDATE meal_residents SET meal_id = #{carried_meal.id} WHERE id = #{row.id}",
                     /meal #{carried_meal.id} is reconciled/)
      expect_refused("UPDATE meal_residents SET meal_id = #{meal.id} WHERE id = #{away.id}",
                     /meal #{carried_meal.id} is reconciled/)
    end

    it 'cannot be written once the setting is off again' do
      set('comeals.correcting', '')

      expect_refused(add_eater(meal.id), /meal #{meal.id} is reconciled/)
    end
  end

  describe 'rolling back the migration' do
    def migrate_down
      $stdout = StringIO.new
      CreateMealCorrections.new.migrate(:down)
    ensure
      $stdout = STDOUT
    end

    it 'refuses to drop the record of a correction' do
      correction_id

      expect { migrate_down }.to raise_error(StandardError, /meal_corrections holds 1 correction\(s\)/)
      expect(MealCorrection.count).to eq(1)
    end
  end
end
