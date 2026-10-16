# frozen_string_literal: true

require 'rails_helper'

# The "Mark these blank costs as No cost" button on the settlement
# preview (ADR 0011 rule 4). It changes only the listed costs that are
# still blank, and says why it left each other one alone. The race with
# a cook entering a cost at the same moment is in
# spec/db/no_cost_marking_race_spec.rb.
RSpec.describe NoCostMarking do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:latest) { Reconciliation.latest_cutoff(community.today) }
  let(:eater) { create(:resident, community: community, unit: unit) }
  let(:admin) { create(:admin_user, community: community, superuser: true) }

  def dinner(date = latest, eaters: [eater])
    meal = create(:meal, community: community, date: date)
    eaters.each { |person| create(:meal_resident, meal: meal, resident: person, community: community) }
    meal
  end

  def cost(meal, amount = 0, no_cost: false)
    create(:bill, meal: meal, resident: create(:resident, community: community, unit: unit), community: community,
                  amount: BigDecimal(amount.to_s), no_cost: no_cost)
  end

  it 'marks each listed blank cost No cost, and records the admin in its history' do
    first = cost(dinner(latest - 1))
    second = cost(dinner)

    result = Audited.audit_class.as_user(admin) { described_class.call(bill_ids: [first.id, second.id]) }

    expect(result.marked).to contain_exactly(first, second)
    expect(result.left_alone).to eq([])
    expect(result.gone).to eq(0)
    expect(Bill.where(id: [first.id, second.id]).pluck(:no_cost, :amount))
      .to eq([[true, BigDecimal('0')], [true, BigDecimal('0')]])
    expect(first.audits.last).to have_attributes(user: admin, action: 'update',
                                                 audited_changes: { 'no_cost' => [false, true] })
  end

  it 'leaves alone a listed cost that changed after the list was shown, and says why' do
    # A dinner nobody ate settles with a blank cost (ADR 0011 rule 3), so
    # its cost can be on a list made before the settlement.
    settled = cost(dinner(latest - 2, eaters: []))
    settle!(cutoff: latest - 2)
    entered = cost(dinner(latest - 1), 12)
    marked_already = cost(dinner, 0, no_cost: true)

    result = described_class.call(bill_ids: [entered.id, marked_already.id, settled.id])

    expect(result.marked).to eq([])
    expect(result.left_alone.map { |left| [left.bill, left.reason] }).to contain_exactly(
      [settled, 'the dinner was settled'],
      [entered, 'the cook entered a cost'],
      [marked_already, 'it was marked No cost already']
    )
    expect(entered.reload).to have_attributes(amount: BigDecimal('12'), no_cost: false)
    expect(settled.reload.no_cost).to be(false)
  end

  it 'marks the blank costs on a list that also has changed ones' do
    blank = cost(dinner)
    entered = cost(blank.meal, 12)

    result = described_class.call(bill_ids: [entered.id, blank.id])

    expect(result.marked).to eq([blank])
    expect(result.left_alone.map(&:bill)).to eq([entered])
  end

  it 'counts a listed cost that was deleted, once, however often it is listed' do
    deleted = cost(dinner)
    deleted_id = deleted.id
    deleted.destroy!
    blank = cost(deleted.meal)

    result = described_class.call(bill_ids: [deleted_id, blank.id, blank.id, deleted_id])

    expect(result.gone).to eq(1)
    expect(result.marked).to eq([blank])
  end

  # The page names each cost from its dinner and cook after the commit,
  # and a read after the commit could fail for a change that is saved
  # (spec/requests/no_query_after_commit_spec.rb).
  it 'comes back with each cost\'s dinner and cook loaded' do
    blank = cost(dinner)
    entered = cost(dinner(latest - 1), 12)

    result = described_class.call(bill_ids: [blank.id, entered.id])

    bills = result.marked + result.left_alone.map(&:bill)
    expect(bills.map { |bill| [bill.association(:meal).loaded?, bill.association(:resident).loaded?] })
      .to eq([[true, true], [true, true]])
  end

  # Nothing is saved here, so no save loads a cost's dinner or cook on
  # the way.
  it "comes back with each cost's dinner and cook loaded when it changes none" do
    entered = cost(dinner, 12)
    marked_already = cost(dinner(latest - 1), 0, no_cost: true)

    result = described_class.call(bill_ids: [entered.id, marked_already.id])

    expect(result.marked).to eq([])
    bills = result.left_alone.map(&:bill)
    expect(bills.map { |bill| [bill.association(:meal).loaded?, bill.association(:resident).loaded?] })
      .to eq([[true, true], [true, true]])
  end

  # In id order, whatever order the table holds the rows in, so the page
  # lists them the same way every time. The update moves the first row
  # after the second in the table.
  it 'gives the costs in id order' do
    first = cost(dinner(latest - 1))
    second = cost(dinner)
    first.update_columns(updated_at: first.updated_at + 1)

    result = described_class.call(bill_ids: [second.id, first.id])

    expect(result.marked).to eq([first, second])
  end

  # The same lock and order as a settlement's claim, taken before the
  # costs are read, so a cook's save waits for it (ADR 0003).
  it 'locks the meals FOR UPDATE in id order before it reads the costs' do
    costs = [cost(dinner), cost(dinner(latest - 1))]
    statements = []
    callback = ->(*, payload) { statements << payload[:sql] }

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      described_class.call(bill_ids: costs.map(&:id))
    end

    lock = statements.index { |sql| sql.match?(/\ASELECT .* FROM "meals" .*ORDER BY "meals"\."id" ASC FOR UPDATE\z/) }
    read = statements.index { |sql| sql.start_with?('SELECT "bills".* FROM "bills" WHERE "bills"."id" IN ') }
    expect(lock).not_to be_nil
    expect(read).to be > lock
  end
end
