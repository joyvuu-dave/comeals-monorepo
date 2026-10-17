# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261016130000_mark_the_potluck_costs_no_cost.rb')

# The data migration that marks No cost on the two $1.00 cook costs of the
# potluck of 2024-11-24, whose sign-up was on paper, so the dinner can
# settle with no money moving.
RSpec.describe MarkThePotluckCostsNoCost do
  let(:migration) { described_class.new }
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:first_cook) { create(:resident, community: community, unit: unit, name: 'Fay First') }
  let(:second_cook) { create(:resident, community: community, unit: unit, name: 'Sam Second') }
  let(:potluck) { create(:meal, community: community, date: described_class::DINNER) }

  def cost(cook, amount = 1)
    create(:bill, meal: potluck, resident: cook, community: community, amount: amount)
  end

  def migrate(direction)
    out = StringIO.new
    $stdout = out
    migration.migrate(direction)
    out.string
  ensure
    $stdout = STDOUT
  end

  def costs
    Bill.where(meal: potluck).order(:id).map { |bill| [bill.amount, bill.no_cost] }
  end

  def fix_rows
    Audited::Audit.where(auditable_type: 'Bill', comment: described_class::COMMENT)
  end

  before do
    cost(first_cook)
    cost(second_cook)
  end

  describe 'up' do
    it 'marks both $1.00 costs No cost, with amount 0' do
      migrate(:up)

      expect(costs).to eq([[0, true], [0, true]])
    end

    it 'writes the audit row a save would write, by no person, and the meal history says Automatic fix' do
      migrate(:up)

      expect(fix_rows.order(:auditable_id).map(&:audited_changes))
        .to eq([{ 'amount' => %w[1.0 0.0], 'no_cost' => [false, true] }] * 2)
      expect(fix_rows).to all(have_attributes(associated_id: potluck.id, user_id: nil, username: nil,
                                              action: 'update', version: 2))
      expect(AuditSerializer.new(potluck.reload.total_audits).to_h.first).to include(user_name: 'Automatic fix')
    end

    it 'moves updated_at on the meal' do
      potluck.update_column(:updated_at, 1.day.ago)
      before = potluck.reload.updated_at

      migrate(:up)

      expect(potluck.reload.updated_at).to be > before
    end

    it 'lets the dinner settle, and no money moves' do
      cutoff = described_class::DINNER + 1
      expect(Settlement.preview(cutoff: cutoff).held_meals).to include(potluck)

      migrate(:up)
      settle!(cutoff: cutoff)

      expect(potluck.reload.reconciliation_id).not_to be_nil
      expect(ResidentBalance.where.not(amount: 0)).to be_empty
    end

    it 'prints what it did, for the release log' do
      expect(migrate(:up)).to include("#{described_class::DINNER}  marked the 2 $1.00 costs No cost")
    end

    # No money moves, so a dinner that is not as expected is skipped and
    # printed, and the deploy goes on.
    it 'skips a dinner with a sign-up in the app' do
      create(:meal_resident, meal: potluck, resident: first_cook, community: community)

      expect(migrate(:up)).to include('skipped: 1 sign-up(s) in the app')
      expect(costs).to eq([[1, false], [1, false]])
    end

    it 'skips a dinner with a guest' do
      create(:guest, meal: potluck, resident: first_cook)

      expect(migrate(:up)).to include('skipped: 1 guest(s)')
      expect(costs).to eq([[1, false], [1, false]])
    end

    it 'skips a dinner with a third cook' do
      cost(create(:resident, community: community, unit: unit, name: 'Tia Third'))

      expect(migrate(:up)).to include('skipped: it has 3 cooks, not 2')
      expect(costs).to all(eq([1, false]))
    end

    it 'skips a dinner where a cost is not $1.00' do
      Bill.find_by!(meal: potluck, resident: second_cook).update!(amount: 12)

      expect(migrate(:up)).to include('skipped: a cost is not $1.00')
      expect(costs).to eq([[1, false], [12, false]])
    end

    it 'skips a settled dinner' do
      create(:meal_resident, meal: potluck, resident: first_cook, community: community)
      settle!(cutoff: described_class::DINNER + 1)

      expect(migrate(:up)).to include('skipped: the dinner is settled')
      expect(costs).to eq([[1, false], [1, false]])
    end

    it 'does nothing, and says so, when it ran already' do
      migrate(:up)

      expect(migrate(:up)).to include('This migration marked the potluck costs already')
      expect(fix_rows.count).to eq(2)
    end

    it 'does nothing, and says so, on a database with no meal on that date' do
      Bill.where(meal: potluck).delete_all
      potluck.delete

      expect(migrate(:up)).to include("No meal on #{described_class::DINNER}")
    end
  end

  describe 'down' do
    it 'puts both $1.00 costs back, and removes its rows' do
      migrate(:up)

      migrate(:down)

      expect(costs).to eq([[1, false], [1, false]])
      expect(fix_rows).to be_empty
    end

    it 'refuses when a cost it marked changed since' do
      migrate(:up)
      Bill.find_by!(meal: potluck, resident: first_cook).update!(no_cost: false, amount: 3)

      expect { migrate(:down) }.to raise_error(RuntimeError, /changed after migration 20261016130000/)
    end
  end
end
