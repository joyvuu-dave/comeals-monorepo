# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# Pins issue #10: billing:recalculate must read all source data from one
# database snapshot. The task loads meals, bills, attendance, and residents
# in separate queries. Unreconciled meals are mutable, so a meal edit that
# commits between two of those queries would otherwise produce balances
# matching no real state of the ledger.
RSpec.describe 'billing:recalculate snapshot isolation' do
  # This spec needs a writer committing on a second connection while the
  # task reads. Transactional fixtures would hide that commit (and Rails
  # ignores isolation hints inside the test transaction), so this group
  # writes real rows and cleans them up itself.
  self.use_transactional_tests = false

  before(:all) do
    # Every task spec file calls load_tasks, and each call stacks a duplicate
    # action onto every task (issue #27). A duplicate action would re-run the
    # task body after the concurrent edit commits and overwrite the snapshot
    # result, so reset to exactly one action per task.
    Rake::Task.clear
    Rails.application.load_tasks
  end

  after do
    Rake::Task['billing:recalculate'].reenable

    ResidentBalance.delete_all
    Bill.delete_all
    MealResident.delete_all
    Guest.delete_all
    Meal.delete_all
    Key.delete_all
    Resident.delete_all
    Unit.delete_all
    Community.delete_all
  end

  it 'computes every balance from one snapshot when a meal edit commits mid-read' do
    community = create(:community)
    unit = create(:unit, community: community)
    cook = create(:resident, community: community, unit: unit, multiplier: 2)
    alice = create(:resident, community: community, unit: unit, multiplier: 2)
    bob = create(:resident, community: community, unit: unit, multiplier: 2)

    meal = create(:meal, community: community)
    alice_mr = create(:meal_resident, meal: meal, resident: alice, community: community, multiplier: 2)
    bill = create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('50'))

    # Right after the task's bills preload runs, commit an atomic meal edit
    # from a second connection: Alice out, Bob in, bill corrected to $30.
    # The task's remaining reads (meal_residents, guests, residents) run
    # after this commit. Without a shared snapshot the task mixes the two
    # states and debits Bob $50 for a $30 meal — issue #10's scenario.
    # The writer is a raw PG connection: the test pool only has one
    # connection, and the edit stands in for a request that already passed
    # the model guards and committed.
    db = ActiveRecord::Base.connection_db_config.configuration_hash
    writer = PG.connect(
      host: db[:host], port: db[:port], user: db[:username],
      password: db[:password], dbname: db[:database]
    )
    commit_concurrent_meal_edit = lambda do
      writer.transaction do |conn|
        conn.exec_params('UPDATE bills SET amount = $1 WHERE id = $2', ['30', bill.id])
        conn.exec_params('DELETE FROM meal_residents WHERE id = $1', [alice_mr.id])
        conn.exec_params(
          'INSERT INTO meal_residents (community_id, meal_id, resident_id, multiplier, ' \
          'created_at, updated_at) VALUES ($1, $2, $3, $4, now(), now())',
          [community.id, meal.id, bob.id, 2]
        )
      end
    end

    triggered = false
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |event|
      next if triggered || event.payload[:name] != 'Bill Load'

      triggered = true
      commit_concurrent_meal_edit.call
    end

    begin
      Rake::Task['billing:recalculate'].invoke
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
      writer.close
    end

    expect(triggered).to be(true)
    expect(bill.reload.amount).to eq(BigDecimal('30'))

    balances = ResidentBalance.where(resident: [cook, alice, bob]).index_by(&:resident_id)
    # The task's snapshot began before the edit committed, so every balance
    # must reflect the before-state: cook credited $50 for his $50 bill,
    # Alice (the only attendee then) debited $50, Bob untouched.
    expect(balances[cook.id].amount).to eq(BigDecimal('50'))
    expect(balances[alice.id].amount).to eq(BigDecimal('-50'))
    expect(balances[bob.id].amount).to eq(BigDecimal('0'))
  end
end
