# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261012120100_delete_a_dinner_nobody_ate_at.rb')

# The data migration that deletes one meal. A few people signed up for it,
# nobody cooked, and the owner says nobody ate. It charges nobody and can
# never settle, so it would wait in every settlement preview.
RSpec.describe DeleteADinnerNobodyAteAt do
  let(:migration) { described_class.new }
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:meal) { create(:meal, community: community, date: described_class::DATE) }
  let!(:sign_ups) do
    %w[Ann Bob].map do |name|
      create(:meal_resident, meal: meal, resident: person(name), community: community)
    end
  end
  # The same rotation: a rotation keeps at least one meal.
  let!(:other_meal) { create(:meal, community: community, date: described_class::DATE + 3, rotation: meal.rotation) }

  def person(name)
    create(:resident, community: community, unit: unit, name: "#{name} Smith")
  end

  def migrate(direction)
    out = StringIO.new
    $stdout = out
    migration.migrate(direction)
    out.string
  ensure
    $stdout = STDOUT
  end

  def fix_rows
    Audited::Audit.where(comment: described_class::COMMENT)
  end

  describe 'up' do
    it 'deletes the meal and its sign-ups, and nothing else' do
      migrate(:up)

      expect(Meal.where(date: described_class::DATE)).to be_empty
      expect(MealResident.where(id: sign_ups.map(&:id))).to be_empty
      expect(other_meal.reload).to be_present
    end

    it 'writes a delete row for the meal and for each sign-up, by no person' do
      versions = sign_ups.map { |row| row.audits.maximum(:version) }
      meal_version = meal.audits.maximum(:version)

      migrate(:up)

      expect(fix_rows.where(auditable_type: 'MealResident').order(:auditable_id)
                     .pluck(:auditable_id, :action, :version, :associated_type, :associated_id))
        .to eq(sign_ups.each_with_index.map { |row, i| [row.id, 'destroy', versions[i] + 1, 'Meal', meal.id] })
      expect(fix_rows.find_by!(auditable_type: 'Meal'))
        .to have_attributes(auditable_id: meal.id, action: 'destroy', version: meal_version + 1)
      expect(fix_rows.find_by!(auditable_type: 'Meal').audited_changes).to include('date' => '2026-04-06')
      expect(fix_rows).to all(have_attributes(user_id: nil, username: nil))
    end

    it 'prints what it deleted, for the release log' do
      expect(migrate(:up)).to include('Deleted the meal of 2026-04-06 and its 2 sign-up(s).')
    end

    it 'takes the meal lock before it deletes anything' do
      statements = []
      callback = ->(*, payload) { statements << payload[:sql] }
      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { migrate(:up) }

      lock = statements.index { |sql| sql.include?('FROM meals') && sql.include?('FOR UPDATE') }
      write = statements.index { |sql| sql.start_with?('DELETE FROM meal_residents') }
      expect(lock).not_to be_nil
      expect(write).not_to be_nil
      expect(lock).to be < write
    end

    it 'does nothing, and says so, when there is no meal that day' do
      migrate(:up)

      expect(migrate(:up)).to include('No meal on 2026-04-06')
      expect(fix_rows.count).to eq(3)
    end

    it 'leaves a settled meal as it is, and says so' do
      create(:bill, meal: meal, resident: person('Cal'), community: community, amount: 10)
      settle!(cutoff: described_class::DATE)
      raise 'setup failed: the meal was not settled' unless meal.reload.reconciled?

      expect(migrate(:up)).to include('Left the meal of 2026-04-06 as it is: it is settled.')
      expect(meal.reload).to be_present
      expect(fix_rows).to be_empty
    end

    # Not money: a meal that does not fit is left as it is and named in the
    # release log, and the deploy goes on.
    {
      'a cook is on it' => -> { create(:bill, meal: meal, resident: person('Cal'), community: community, amount: 0) },
      'a guest is on it' => -> { create(:guest, meal: meal, resident: sign_ups.first.resident) },
      'a third person signed up' => lambda {
        create(:meal_resident, meal: meal, resident: person('Dee'), community: community)
      },
      'one of the two took their name off' => -> { sign_ups.first.delete },
      'it is the only meal of its rotation' => -> { other_meal.delete }
    }.each do |state, arrange|
      it "leaves the meal as it is, and says why, when #{state}" do
        instance_exec(&arrange)

        expect(migrate(:up)).to include('Left the meal of 2026-04-06 as it is')
        expect(meal.reload).to be_present
        expect(fix_rows).to be_empty
      end
    end
  end

  describe 'down' do
    it 'refuses: a deleted meal cannot come back from here' do
      migrate(:up)

      expect { migrate(:down) }.to raise_error(ActiveRecord::IrreversibleMigration, /audit rows/)
    end
  end

  it_behaves_like 'a data migration that tries a conflict again', described_class
end
