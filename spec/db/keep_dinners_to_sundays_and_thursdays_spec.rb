# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261012120200_keep_dinners_to_sundays_and_thursdays.rb')

# The data migration that makes the meal schedule Sundays and Thursdays,
# and deletes the upcoming Monday and Tuesday meals nobody signed up for.
# Nobody has eaten a Monday or Tuesday dinner since 2021, and admins kept
# closing them by hand.
RSpec.describe KeepDinnersToSundaysAndThursdays do
  include ActiveSupport::Testing::TimeHelpers

  let(:migration) { described_class.new }
  let(:community) { create(:community, schedule: described_class::OLD_SCHEDULE) }
  let(:rotation) { create(:rotation, community: community) }
  # Monday 2026-10-12, noon in the community's zone.
  let(:today) { Date.new(2026, 10, 12) }
  let(:next_monday) { Date.new(2026, 10, 19) }
  let(:next_tuesday) { Date.new(2026, 10, 13) }

  before { travel_to(ActiveSupport::TimeZone['America/Los_Angeles'].local(2026, 10, 12, 12)) }

  def meal_on(date, **attributes)
    create(:meal, community: community, rotation: rotation, date: date, **attributes)
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
    let!(:sunday) { meal_on(Date.new(2026, 10, 18)) }
    let!(:thursday) { meal_on(Date.new(2026, 10, 15)) }
    let!(:tuesday) { meal_on(next_tuesday) }
    let!(:closed_monday) { meal_on(next_monday, closed: true, closed_at: Time.current) }
    let!(:past_monday) { meal_on(Date.new(2026, 10, 5)) }
    let!(:today_monday) { meal_on(today) }

    it 'sets the schedule to Sundays and Thursdays' do
      migrate(:up)

      expect(community.reload.schedule).to eq(described_class::NEW_SCHEDULE)
    end

    it 'moves the community updated_at, so the calendar version moves' do
      community.update_columns(updated_at: 1.day.ago)

      migrate(:up)

      expect(community.reload.updated_at).to eq(Time.current)
    end

    it 'deletes the upcoming Monday and Tuesday meals with nothing on them, closed ones too' do
      migrate(:up)

      expect(Meal.where(id: [tuesday.id, closed_monday.id])).to be_empty
    end

    it 'keeps every Sunday and Thursday, every past Monday, and the meal of today' do
      migrate(:up)

      expect(Meal.where(id: [sunday, thursday, past_monday, today_monday].map(&:id)).count).to eq(4)
    end

    it 'writes a delete row for each meal it deletes, by no person' do
      migrate(:up)

      expect(fix_rows.order(:auditable_id).pluck(:auditable_type, :auditable_id, :action))
        .to eq([['Meal', tuesday.id, 'destroy'], ['Meal', closed_monday.id, 'destroy']])
      expect(fix_rows).to all(have_attributes(user_id: nil, username: nil))
    end

    it 'prints each meal it deleted, for the release log' do
      out = migrate(:up)

      expect(out).to include('Set the meal schedule to Sundays and Thursdays.')
      expect(out).to include('Deleted 2 upcoming Monday and Tuesday meal(s) with nobody on them: ' \
                             '2026-10-13, 2026-10-19.')
    end

    it 'makes the next rotation of Sundays and Thursdays only' do
      migrate(:up)

      dates = community.reload.create_next_rotation.meals.map(&:date)
      expect(dates.map(&:wday).uniq.sort).to eq([0, 4])
    end

    {
      'someone signed up' => ->(meal) { create(:meal_resident, meal: meal, community: community) },
      'a cook is on it' => ->(meal) { create(:bill, meal: meal, community: community, amount: 0) }
    }.each do |state, arrange|
      it "keeps an upcoming Tuesday meal, and names it, when #{state}" do
        instance_exec(tuesday, &arrange)

        out = migrate(:up)

        expect(tuesday.reload).to be_present
        expect(out).to include('Kept 1 upcoming Monday or Tuesday meal(s) because someone is on them: 2026-10-13.')
      end
    end

    it 'keeps a meal that is the only one of its rotation' do
      lonely = create(:meal, community: community, date: Date.new(2026, 10, 26))

      out = migrate(:up)

      expect(lonely.reload).to be_present
      expect(out).to include('Kept 1 meal(s) that would leave a rotation empty: 2026-10-26.')
    end

    it 'does nothing more, and says so, when it ran already' do
      migrate(:up)

      expect(migrate(:up)).to include('The meal schedule is already Sundays and Thursdays.')
      expect(fix_rows.count).to eq(2)
    end

    it 'changes nothing when an admin set another schedule, and says so' do
      community.update_columns(schedule: [[0, 3]])

      out = migrate(:up)

      expect(out).to include('Left the meal schedule as it is')
      expect(community.reload.schedule).to eq([[0, 3]])
      expect(Meal.where(id: [tuesday.id, closed_monday.id]).count).to eq(2)
    end
  end

  describe 'down' do
    it 'refuses: deleted meals cannot come back from here' do
      expect { migrate(:down) }.to raise_error(ActiveRecord::IrreversibleMigration, /community form/)
    end
  end
end
