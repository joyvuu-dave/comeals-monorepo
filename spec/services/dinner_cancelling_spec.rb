# frozen_string_literal: true

require 'rails_helper'

# The "Mark these dinners as cancelled" button on the settlement preview
# (ADR 0011 rule 11). It cancels only the listed dinners that still have
# no cook, and says why it left each other one alone. The race with a
# cook signing up at the same moment is in
# spec/db/dinner_cancelling_race_spec.rb.
RSpec.describe DinnerCancelling do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:latest) { Reconciliation.latest_cutoff(community.today) }
  let(:eater) { create(:resident, community: community, unit: unit) }
  let(:admin) { create(:admin_user, community: community, superuser: true) }

  def dinner(date = latest)
    meal = create(:meal, community: community, date: date)
    create(:meal_resident, meal: meal, resident: eater, community: community)
    meal
  end

  def cook(meal, no_cost: false)
    create(:bill, meal: meal, resident: create(:resident, community: community, unit: unit), community: community,
                  amount: 0, no_cost: no_cost)
  end

  it 'cancels each listed dinner, keeps its sign-ups, and records the admin in its history' do
    first = dinner(latest - 1)
    second = dinner

    result = Audited.audit_class.as_user(admin) { described_class.call(meal_ids: [first.id, second.id]) }

    expect(result.cancelled).to contain_exactly(first, second)
    expect(result.left_alone).to eq([])
    expect(result.gone).to eq(0)
    expect(Meal.where(id: [first.id, second.id]).where.not(cancelled_at: nil).count).to eq(2)
    expect(first.meal_residents.pluck(:resident_id)).to eq([eater.id])
    expect(first.audits.last).to have_attributes(user: admin, action: 'update')
    expect(first.audits.last.audited_changes.keys).to eq(['cancelled_at'])
  end

  it 'leaves alone a listed dinner that changed after the list was shown, and says why' do
    # A dinner settled since the list was made: the list came from a
    # preview, and a cook who spent nothing was added and a settlement
    # made after it.
    settled = dinner(latest - 2)
    cook(settled, no_cost: true)
    settle!(cutoff: latest - 2)
    cooked = dinner(latest - 1)
    cook(cooked)
    cancelled_already = dinner
    cancelled_already.cancel!
    cancelled_at = cancelled_already.reload.cancelled_at

    result = described_class.call(meal_ids: [cooked.id, cancelled_already.id, settled.id])

    expect(result.cancelled).to eq([])
    expect(result.left_alone.map { |left| [left.meal, left.reason] }).to contain_exactly(
      [settled, 'it was settled'],
      [cooked, 'a cook signed up for it'],
      [cancelled_already, 'it was cancelled already']
    )
    expect(Meal.where(id: [settled.id, cooked.id]).where.not(cancelled_at: nil)).to be_empty
    expect(cancelled_already.reload.cancelled_at).to eq(cancelled_at)
  end

  it 'cancels the dinners on a list that also has changed ones' do
    nobody_cooked = dinner(latest - 1)
    cooked = dinner
    cook(cooked)

    result = described_class.call(meal_ids: [cooked.id, nobody_cooked.id])

    expect(result.cancelled).to eq([nobody_cooked])
    expect(result.left_alone.map(&:meal)).to eq([cooked])
  end

  it 'leaves a dinner that is not on the list as it is, though nobody cooked it' do
    listed = dinner(latest - 1)
    not_listed = dinner

    result = described_class.call(meal_ids: [listed.id])

    expect(result.cancelled).to eq([listed])
    expect(result.left_alone).to eq([])
    expect(not_listed.reload.cancelled?).to be(false)
  end

  it 'counts a listed dinner that was deleted, once, however often it is listed' do
    deleted = create(:meal, community: community, date: latest - 1)
    deleted_id = deleted.id
    deleted.destroy!
    listed = dinner

    result = described_class.call(meal_ids: [deleted_id, listed.id, listed.id, deleted_id])

    expect(result.gone).to eq(1)
    expect(result.cancelled).to eq([listed])
  end

  # The same lock and order as a settlement's claim, taken before the
  # cooks are read, so a cook's sign-up waits for it (ADR 0003).
  it 'locks the meals FOR UPDATE in id order before it reads the cooks' do
    meals = [dinner, dinner(latest - 1)]
    statements = []
    callback = ->(*, payload) { statements << payload[:sql] }

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      described_class.call(meal_ids: meals.map(&:id))
    end

    lock = statements.index do |sql|
      sql.match?(/\ASELECT "meals".* FROM "meals" .*ORDER BY "meals"\."id" ASC FOR UPDATE\z/)
    end
    read = statements.index { |sql| sql.start_with?('SELECT DISTINCT "bills"."meal_id" FROM "bills"') }
    expect(lock).not_to be_nil
    expect(read).to be > lock
  end
end
