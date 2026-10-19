# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261013120300_mark_costs_the_cooks_said_were_nothing.rb')

# The data migration that marks No cost on blank cook costs whose cooks
# said they spent nothing: on some dinners the blank cost of a cook whose
# household's other cook entered the receipt, and on one dinner the only
# blank cost.
RSpec.describe MarkCostsTheCooksSaidWereNothing do
  let(:migration) { described_class.new }
  let(:community) { create(:community) }
  let(:home) { create(:unit, community: community) }
  let(:next_door) { create(:unit, community: community) }
  let(:payer) { person('Kay Payer', home) }
  let(:partner) { person('Pip Partner', home) }
  let(:neighbor) { person('Ned Neighbor', next_door) }
  let(:eater) { person('Eli Eater', next_door) }
  let(:shared) { dinner(described_class::SAME_HOUSEHOLD.first, [payer, 100], [partner, 0], [neighbor, 0]) }
  let(:helped) { dinner(described_class::ONLY_BLANK.first, [payer, 90], [neighbor, 0]) }

  def person(name, unit)
    create(:resident, community: community, unit: unit, name: name)
  end

  def dinner(date, *costs)
    meal = create(:meal, community: community, date: date)
    costs.each { |cook, amount| create(:bill, meal: meal, resident: cook, community: community, amount: amount) }
    create(:meal_resident, meal: meal, resident: eater, community: community)
    meal
  end

  def migrate(direction)
    out = StringIO.new
    $stdout = out
    migration.migrate(direction)
    out.string
  ensure
    $stdout = STDOUT
  end

  def no_cost(meal, cook)
    Bill.find_by!(meal: meal, resident: cook).no_cost
  end

  def fix_rows
    Audited::Audit.where(auditable_type: 'Bill', comment: described_class::COMMENT)
  end

  before do
    shared
    helped
  end

  describe 'up' do
    it "marks the blank cost of the payer's household, and the only blank cost, and no other" do
      migrate(:up)

      expect(no_cost(shared, partner)).to be(true)
      expect(no_cost(shared, neighbor)).to be(false)
      expect(no_cost(helped, neighbor)).to be(true)
      expect(no_cost(shared, payer)).to be(false)
    end

    it 'moves no money' do
      BalanceRecalculation.call
      before = ResidentBalance.pluck(:resident_id, :amount).sort

      migrate(:up)
      BalanceRecalculation.call

      expect(ResidentBalance.pluck(:resident_id, :amount).sort).to eq(before)
    end

    it 'writes the audit row a save would write, by no person, and the meal history says Automatic fix' do
      migrate(:up)

      expect(fix_rows.order(:associated_id).map { |row| [row.associated_id, row.audited_changes] })
        .to eq([[shared.id, { 'no_cost' => [false, true] }], [helped.id, { 'no_cost' => [false, true] }]])
      expect(fix_rows).to all(have_attributes(user_id: nil, username: nil, action: 'update', version: 2))
      expect(AuditSerializer.new(shared.reload.total_audits).to_h.first).to include(user_name: 'Automatic fix')
    end

    it 'prints each dinner it marked, for the release log' do
      out = migrate(:up)

      expect(out).to include("#{shared.date}  marked the blank cost No cost")
      expect(out).to include("#{helped.date}  marked the blank cost No cost")
    end

    # No money moves, so a dinner that is not as expected is skipped and
    # printed, and the deploy goes on.
    it 'skips a dinner whose cost was entered since, and says so' do
      Bill.find_by!(meal: shared, resident: partner).update!(amount: 5)

      out = migrate(:up)

      expect(out).to include("#{shared.date}  skipped: no blank cost matches (one may have been entered since)")
      expect(no_cost(helped, neighbor)).to be(true)
    end

    it 'skips a dinner with more than one blank cost that matches' do
      create(:bill, meal: helped, resident: partner, community: community, amount: 0)

      expect(migrate(:up)).to include("#{helped.date}  skipped: 2 blank costs match, not 1")
      expect(no_cost(helped, neighbor)).to be(false)
    end

    it 'skips a settled dinner' do
      settle_as_before_rule_3!(cutoff: shared.date + 1)

      expect(migrate(:up)).to include("#{shared.date}  skipped: the dinner is settled")
      expect(no_cost(shared, partner)).to be(false)
    end

    it 'marks nothing when every dinner is skipped' do
      settle_as_before_rule_3!(cutoff: [shared.date, helped.date].max + 1)

      out = migrate(:up)

      expect(out).to include("#{shared.date}  skipped: the dinner is settled",
                             "#{helped.date}  skipped: the dinner is settled")
      expect(fix_rows).to be_empty
    end

    it 'does nothing, and says so, when it ran already' do
      migrate(:up)

      expect(migrate(:up)).to include('This migration marked the costs already')
      expect(fix_rows.count).to eq(2)
    end

    it 'does nothing, and says so, on a database with no meal on those dates' do
      [shared, helped].each do |meal|
        Bill.where(meal: meal).delete_all
        MealResident.where(meal: meal).delete_all
        meal.delete
      end

      expect(migrate(:up)).to include('No meal on any of these dates')
    end
  end

  describe 'down' do
    it 'takes No cost off exactly the costs it marked, and removes its rows' do
      migrate(:up)

      migrate(:down)

      expect([no_cost(shared, partner), no_cost(helped, neighbor)]).to eq([false, false])
      expect(fix_rows).to be_empty
    end

    it 'does nothing, and says so, when up marked no cost' do
      expect(migrate(:down)).to include('This migration marked no cost: nothing to take back.')
      expect(no_cost(shared, partner)).to be(false)
    end

    it 'refuses when a cost it marked changed since' do
      migrate(:up)
      Bill.find_by!(meal: shared, resident: partner).update!(no_cost: false, amount: 3)

      expect { migrate(:down) }.to raise_error(RuntimeError, /changed, or its dinner was settled/)
    end
  end

  it_behaves_like 'a data migration that tries a conflict again', described_class
end
