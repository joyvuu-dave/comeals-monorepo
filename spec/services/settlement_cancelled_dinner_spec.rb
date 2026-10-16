# frozen_string_literal: true

require 'rails_helper'

# A settlement and a cancelled dinner (ADR 0011 rule 11): the settlement
# takes it in, with every line at $0, locks it, names no cook of it, and
# the preview says it was cancelled. A correction cannot change it.
RSpec.describe Settlement do
  describe 'a cancelled dinner' do
    let(:community) { create(:community) }
    let(:unit) { create(:unit, community: community) }
    let(:latest) { Reconciliation.latest_cutoff(community.today) }
    let(:ann) { create(:resident, community: community, unit: unit, name: 'Ann') }
    let(:bob) { create(:resident, community: community, unit: unit, name: 'Bob') }
    let(:cid) { create(:resident, community: community, unit: unit, name: 'Cid') }

    # Cid signed up to cook, entered no cost, and the dinner was called
    # off. Ann and Bob had signed up to eat, and Bob had a guest.
    let!(:cancelled) do
      create(:meal, community: community, date: latest - 1).tap do |meal|
        create(:bill, meal: meal, resident: cid, community: community, amount: 0)
        [ann, bob].each { |person| create(:meal_resident, meal: meal, resident: person, community: community) }
        create(:guest, meal: meal, resident: bob, multiplier: 2)
        meal.cancel!
      end
    end
    # Ann cooked a real dinner the next day, which Bob ate.
    let!(:eaten) do
      create(:meal, community: community, date: latest).tap do |meal|
        create(:bill, meal: meal, resident: ann, community: community, amount: BigDecimal('20'))
        create(:meal_resident, meal: meal, resident: bob, community: community)
      end
    end

    it 'takes it in with every line at $0, and charges only for the real dinner' do
      reconciliation = settle!

      expect(reconciliation.meals).to contain_exactly(cancelled, eaten)
      charges = cancelled.reload.meal_charges.map { |charge| [charge.resident_id, charge.amount] }
      expect(charges).to contain_exactly([cid.id, 0], [ann.id, 0], [bob.id, 0], [bob.id, 0])
      expect(reconciliation.reconciliation_balances.pluck(:resident_id, :amount))
        .to contain_exactly([ann.id, BigDecimal('20')], [bob.id, BigDecimal('-20')])
      expect(MealCostSummary.for(cancelled)).to have_attributes(total_cost: 0, unit_cost: 0, subsidized: false)
    end

    it 'names no cook of it in the settlement mail' do
      reconciliation = settle!

      expect(reconciliation.settled_cook?(ann)).to be(true)
      expect(reconciliation.settled_cook?(cid)).to be(false)
      expect(NotifyCooksJob.recipients(reconciliation)).to contain_exactly(ann)
    end

    it 'says in the preview that it was cancelled, and does not call its blank cost a mistake' do
      preview = described_class.preview(cutoff: latest)
      warnings = ReconciliationWarnings.for(preview.meals, skipped: preview.skipped_meals, held: preview.held_meals,
                                                           waiting: preview.waiting_meals)

      expect(warnings).to eq([{ id: "dinner_cancelled:meal=#{cancelled.id}", kind: 'dinner_cancelled',
                                severity: 'info', meal_id: cancelled.id, title: 'Dinner cancelled',
                                body: "The dinner on #{cancelled.date.iso8601} was cancelled. 3 people signed up, " \
                                      'and nobody is charged for it.' }])
    end

    it 'cannot be corrected once settled' do
      settle!
      admin = create(:admin_user, community: community, superuser: true)

      expect do
        MealCorrecting.save!(cancelled.reload, by: admin, reason: 'It happened after all') do |edits|
          edits.cost(cid, amount: BigDecimal('10'), no_cost: false)
        end
      end.to raise_error(MealCorrecting::Cancelled,
                         "Meal #{cancelled.id} was cancelled, so it charged nobody and has nothing to correct.")
    end

    it 'leaves its blank cost alone when the No cost button is pressed' do
      result = NoCostMarking.call(bill_ids: cancelled.bills.ids)

      expect(result.marked).to be_empty
      expect(result.left_alone.map(&:reason)).to eq(['the dinner was cancelled'])
    end

    it 'is left out of the dashboard averages, and counted as cancelled' do
      expect(community.averaged_meals).to contain_exactly(eaten)
      expect(community.meals_left_out_of_averages).to include(cancelled: 1, no_cook: 0, cost_not_entered: 0)
    end
  end
end
