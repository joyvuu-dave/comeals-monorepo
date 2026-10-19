# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261015120000_cancel_old_dinners_nobody_cooked.rb')

# The data migration that marks cancelled every dinner before October 2026
# that people signed up for and nobody cooked, and that is not settled
# (ADR 0011 rule 11).
RSpec.describe CancelOldDinnersNobodyCooked do
  let(:migration) { described_class.new }
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:eater) { create(:resident, community: community, unit: unit, name: 'Eli Eater') }
  let(:cook) { create(:resident, community: community, unit: unit, name: 'Cal Cook') }
  let(:before) { described_class::BEFORE }
  # The two dinners the rule takes: one with a sign-up, one with only a
  # guest.
  let!(:signed_up) { dinner(Date.new(2024, 7, 11)) }
  let!(:guest_only) { dinner(before - 1, eaters: [], guest_of: eater) }

  def dinner(date, eaters: [eater], guest_of: nil)
    meal = create(:meal, community: community, date: date)
    eaters.each { |person| create(:meal_resident, meal: meal, resident: person, community: community) }
    create(:guest, meal: meal, resident: guest_of) if guest_of
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

  def cancelled_ids
    Meal.where.not(cancelled_at: nil).order(:id).ids
  end

  def fix_rows
    Audited::Audit.where(auditable_type: 'Meal', comment: described_class::COMMENT)
  end

  describe 'up' do
    it 'cancels the old dinners people signed up for and nobody cooked, and keeps their sign-ups' do
      migrate(:up)

      expect(cancelled_ids).to eq([signed_up.id, guest_only.id])
      expect(signed_up.meal_residents.pluck(:resident_id)).to eq([eater.id])
      expect(guest_only.guests.count).to eq(1)
    end

    it 'leaves alone a dinner with a cook, a dinner from October on, an empty one, and a settled one' do
      with_a_cook = dinner(before - 2)
      create(:bill, meal: with_a_cook, resident: cook, community: community, amount: 0)
      from_october = dinner(before)
      empty = dinner(before - 3, eaters: [])
      settled = dinner(before - 4)
      create(:bill, meal: settled, resident: cook, community: community, amount: 0, no_cost: true)
      settle!(cutoff: before - 4)
      # Settled with sign-ups and no cook, which only a repair can make,
      # so that only the settlement keeps it out.
      SettledWrites.with_repair_bypass { settled.bills.delete_all }

      migrate(:up)

      expect(cancelled_ids).to eq([signed_up.id, guest_only.id])
      expect(Meal.where(id: [with_a_cook.id, from_october.id, empty.id, settled.id]).where.not(cancelled_at: nil))
        .to be_empty
    end

    it 'moves no money' do
      paid = dinner(before - 5)
      create(:bill, meal: paid, resident: cook, community: community, amount: 30)
      BalanceRecalculation.call
      balances = ResidentBalance.pluck(:resident_id, :amount).sort

      migrate(:up)
      BalanceRecalculation.call

      expect(ResidentBalance.pluck(:resident_id, :amount).sort).to eq(balances)
    end

    it 'writes the audit row a save would write, by no person, and the meal history says Automatic fix' do
      migrate(:up)

      expect(fix_rows.order(:auditable_id).map { |row| [row.auditable_id, row.audited_changes.keys] })
        .to eq([[signed_up.id, ['cancelled_at']], [guest_only.id, ['cancelled_at']]])
      # JSON keeps milliseconds, the same as the row a save writes.
      from, to = fix_rows.find_by!(auditable_id: signed_up.id).audited_changes['cancelled_at']
      expect([from, Time.zone.parse(to)]).to eq([nil, signed_up.reload.cancelled_at.floor(3)])
      expect(fix_rows).to all(have_attributes(user_id: nil, username: nil, action: 'update', version: 2))
      history = AuditSerializer.new(signed_up.reload.total_audits).to_h
      expect(history.find { |row| row[:description] == 'Dinner cancelled' })
        .to include(user_name: 'Automatic fix')
    end

    it 'leaves each dinner as a cancel through the app would: the next settlement takes it in at $0' do
      migrate(:up)

      reconciliation = settle!(cutoff: before - 1)

      expect(reconciliation.meals).to contain_exactly(signed_up, guest_only)
      expect(MealCharge.where(meal: [signed_up, guest_only]).pluck(:amount).uniq).to eq([0])
    end

    it 'prints each dinner it cancelled, by date, for the release log' do
      out = migrate(:up)

      expect(out).to include("2024-07-11  cancelled\n")
      expect(out).to include("#{before - 1}  cancelled\n")
      expect(out).to include('Cancelled 2 dinner(s).')
    end

    it 'does nothing, and says so, when it ran already' do
      migrate(:up)
      signed_up.reload.restore!

      expect(migrate(:up)).to include('This migration cancelled the dinners already')
      expect(cancelled_ids).to eq([guest_only.id])
    end

    it 'does nothing, and says so, when no dinner matches' do
      [signed_up, guest_only].each(&:destroy!)

      expect(migrate(:up)).to include("No dinner before #{before} has sign-ups and no cook")
      expect(fix_rows).to be_empty
    end
  end

  describe 'down' do
    it 'restores exactly the dinners it cancelled, and removes its rows' do
      cancelled_by_hand = dinner(Date.new(2025, 3, 2))
      cancelled_by_hand.cancel!
      migrate(:up)

      migrate(:down)

      expect(cancelled_ids).to eq([cancelled_by_hand.id])
      expect(fix_rows).to be_empty
    end

    it 'refuses when a dinner it cancelled was restored and cancelled again since' do
      migrate(:up)
      signed_up.reload.restore!
      signed_up.cancel!

      expect { migrate(:down) }.to raise_error(RuntimeError, /The dinner of 2024-07-11 changed, or was settled/)
      expect(cancelled_ids).to eq([signed_up.id, guest_only.id])
    end

    it 'does nothing, and says so, when up cancelled no dinner' do
      expect(migrate(:down)).to include('This migration cancelled no dinner: nothing to restore.')
      expect(cancelled_ids).to be_empty
    end

    it 'refuses when a dinner it cancelled was settled since' do
      migrate(:up)
      settle!(cutoff: before - 1)

      expect { migrate(:down) }.to raise_error(RuntimeError, /changed, or was settled/)
    end
  end

  it_behaves_like 'a data migration that tries a conflict again', described_class
end
