# frozen_string_literal: true

require 'rails_helper'

# A cancelled dinner (ADR 0011 rule 11): its sign-ups, guests and costs
# stay as they were and charge nobody, only its description changes, and
# a dinner a cook spent money on cannot be cancelled.
RSpec.describe Meal do
  describe 'a cancelled dinner' do
    let(:community) { create(:community) }
    let(:unit) { create(:unit, community: community) }
    let(:ann) { create(:resident, community: community, unit: unit, name: 'Ann') }
    let(:cid) { create(:resident, community: community, unit: unit, name: 'Cid') }
    let(:meal) { create(:meal, community: community) }

    describe '#cancel! and #restore!' do
      it 'sets and clears cancelled_at, and does nothing when the dinner is that way already' do
        expect(meal).not_to be_cancelled

        meal.cancel!
        first = meal.reload.cancelled_at
        expect(meal).to be_cancelled
        meal.cancel!
        expect(meal.reload.cancelled_at).to eq(first)

        meal.restore!
        expect(meal.reload.cancelled_at).to be_nil
        meal.restore!
        expect(meal.reload.cancelled_at).to be_nil
      end

      it 'refuses to cancel a dinner a cook spent money on, read from the bills table' do
        create(:bill, meal: meal, resident: cid, community: community, amount: BigDecimal('0.01'))

        expect { meal.cancel! }
          .to raise_error(ActiveRecord::RecordInvalid, /A cook spent money on this dinner, so it can't be cancelled/)
        expect(meal.reload.cancelled_at).to be_nil
      end

      it 'cancels a dinner whose costs are blank or No cost' do
        create(:bill, meal: meal, resident: cid, community: community, amount: 0)
        create(:bill, meal: meal, resident: ann, community: community, amount: 0, no_cost: true)

        meal.cancel!

        expect(meal.reload).to be_cancelled
      end

      it 'refuses both on a settled dinner' do
        latest = Reconciliation.latest_cutoff(community.today)
        meal.update!(date: latest)
        create(:meal_resident, meal: meal, resident: ann, community: community)
        meal.cancel!
        held = create(:meal, community: community, date: latest - 1)
        create(:bill, meal: held, resident: cid, community: community, amount: 0, no_cost: true)
        create(:meal_resident, meal: held, resident: ann, community: community)
        settle!

        [[meal.reload, :restore!], [held.reload, :cancel!]].each do |dinner, change|
          expect { dinner.public_send(change) }.to raise_error(ActiveRecord::RecordNotSaved)
          expect(dinner.errors.full_messages).to eq(['Meal has been reconciled. cancelled_at cannot change.'])
        end
      end
    end

    describe 'while cancelled' do
      before do
        create(:meal_resident, meal: meal, resident: ann, community: community)
        meal.cancel!
      end

      # Closed before it was cancelled, so a new max is a change too (an
      # open meal clears max before validation).
      it 'takes a new description, and nothing else' do
        meal.restore!
        meal.update!(closed: true)
        meal.cancel!
        meal.update!(description: 'Cook is sick')

        %i[closed max date cap].zip([false, 4, meal.date + 1, BigDecimal('9')]).each do |field, value|
          meal.reload
          expect(meal.update(field => value)).to be(false), "#{field} changed"
          expect(meal.errors.full_messages).to eq(['This dinner is cancelled. Restore it before changing it.'])
        end
      end

      it 'freezes its sign-ups, guests and costs, and says why' do
        add = MealResident.new(meal: meal, resident: cid, community: community)
        guest = Guest.new(meal: meal, resident: ann, multiplier: 2)
        bill = Bill.new(meal: meal, resident: cid, community: community, amount: 0)

        [add, guest, bill].each do |row|
          expect(row.save).to be(false)
          expect(row.errors.full_messages).to include('This dinner is cancelled. Restore it before changing it.')
        end
        expect(MealResident.find_by!(meal: meal, resident: ann).destroy).to be(false)
        expect(MealResident.where(meal: meal).count).to eq(1)
      end

      # The before_save stops a save that skips validation, with the
      # sentence once, before the trigger has to.
      it 'refuses a save that skips validation, with the sentence and not the trigger' do
        row = MealResident.find_by!(meal: meal, resident: ann)
        row.late = true

        expect { row.save(validate: false) }.not_to raise_error
        expect(row.save(validate: false)).to be(false)
        expect(row.errors[:base]).to eq(['This dinner is cancelled. Restore it before changing it.'])
      end

      it 'refuses a row moved onto it from another dinner' do
        other = create(:meal, community: community, date: meal.date + 1)
        bill = create(:bill, meal: other, resident: cid, community: community, amount: 0)

        bill.meal = meal

        expect(bill.save).to be(false)
        expect(bill.errors.full_messages).to include('This dinner is cancelled. Restore it before changing it.')
      end

      it 'refuses to be deleted until it is restored' do
        expect(meal.destroy).to be(false)
        expect(meal.errors.full_messages).to eq(['This dinner is cancelled. Restore it before deleting it.'])

        meal.restore!
        meal.meal_residents.destroy_all
        expect(meal.destroy).to be_truthy
      end
    end

    describe '.settleable_by' do
      let(:latest) { Reconciliation.latest_cutoff(community.today) }

      # A dinner people signed up for and nobody cooked never settles, until
      # it is cancelled; and a cancelled dinner never waits for a cost.
      it 'takes in a cancelled dinner with no cook, or with a blank cost, and never makes it wait' do
        no_cook = create(:meal, community: community, date: latest - 1)
        create(:meal_resident, meal: no_cook, resident: ann, community: community)
        blank = create(:meal, community: community, date: latest)
        create(:bill, meal: blank, resident: cid, community: community, amount: 0)
        create(:meal_resident, meal: blank, resident: ann, community: community)

        expect(described_class.settleable_by(latest)).to be_empty
        expect(described_class.waiting_for_a_cost).to eq([blank])

        [no_cook, blank].each(&:cancel!)

        expect(described_class.settleable_by(latest)).to contain_exactly(no_cook, blank)
        expect(described_class.waiting_for_a_cost).to be_empty
        expect(Settlement.skipped_by(latest, today: community.today)).to be_empty
      end

      it 'still keeps a cancelled dinner from today and later out' do
        meal.update!(date: community.today)
        meal.cancel!

        expect(described_class.settleable_by(community.today)).to be_empty
      end
    end
  end
end
