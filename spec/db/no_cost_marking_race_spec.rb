# frozen_string_literal: true

require 'rails_helper'

# The "Mark these blank costs as No cost" button changes only costs that
# are still blank at the moment of the yes (ADR 0011 rule 4). This races
# it against a cook's cost written at that same moment, and the cost
# must win: it is never marked No cost.
#
# The cook's write is raw SQL on a libpq session of its own, at READ
# COMMITTED, the way psql writes: it takes no meal lock of its own, only
# the one the settled-meal trigger takes. The marking's transaction began
# before the write committed, so its first read of the cost is the old,
# blank one, and only the database's conflict check stops it from writing
# over the new cost: the trigger updated the meal row (20261016120000),
# so the marking's FOR UPDATE on the meal fails as a conflict once the
# cook commits. (Before that migration the trigger left the meal row as
# it was, and the conflict came later, at the marking's write to the same
# bill.) RetryOnConflict then reads the cost again and leaves it alone.
RSpec.describe 'marking blank costs No cost, against a cost entered at the same moment' do
  include_context 'with no test transaction'

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:meal) { create(:meal, community: community, date: Reconciliation.latest_cutoff(community.today)) }
  let(:bill) do
    create(:bill, meal: meal, resident: create(:resident, community: community, unit: unit), community: community,
                  amount: BigDecimal('0'))
  end

  before { create(:meal_resident, meal: meal, resident: create(:resident, community: community, unit: unit)) }

  def open_session
    db = ActiveRecord::Base.connection_db_config.configuration_hash
    PG.connect(host: db[:host], port: db[:port], user: db[:username], password: db[:password], dbname: db[:database])
  end

  # Waits until another session is blocked on a lock while running a
  # statement that contains `sql_fragment`.
  def wait_for_blocked_session(observer, sql_fragment)
    200.times do
      blocked = observer.exec_params(
        'SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() ' \
        "AND pid <> pg_backend_pid() AND wait_event_type = 'Lock' AND query LIKE $1",
        ["%#{sql_fragment}%"]
      ).getvalue(0, 0).to_i.positive?
      return true if blocked

      sleep 0.02
    end
    false
  end

  it 'leaves the cost alone, and never marks it No cost' do
    allow(Rails.error).to receive(:report).and_call_original
    cook = open_session
    observer = open_session
    cook.exec('BEGIN')
    cook.exec_params('UPDATE bills SET amount = 12 WHERE id = $1', [bill.id])

    marking = Thread.new do
      Thread.current.report_on_exception = false
      ActiveRecord::Base.connection_pool.with_connection { NoCostMarking.call(bill_ids: [bill.id]) }
    end
    # The cook's update has updated the meal row (the trigger), so the
    # marking waits at its FOR UPDATE until the cook commits.
    expect(wait_for_blocked_session(observer, 'FOR UPDATE')).to be(true)
    cook.exec('COMMIT')
    result = marking.value

    expect(result.marked).to eq([])
    expect(result.left_alone.map(&:reason)).to eq(['the cook entered a cost'])
    expect(bill.reload).to have_attributes(amount: BigDecimal('12'), no_cost: false)
    # The first try read the old, blank cost, and the database refused its
    # write; the second try read the cost again (RetryOnConflict).
    expect(Rails.error).to have_received(:report)
      .with(an_instance_of(ActiveRecord::SerializationFailure), hash_including(handled: true)).once
  ensure
    cook&.close
    observer&.close
  end

  # The other order, through the app. The marking holds the meal's lock
  # from its read of the costs to its commit, so a cook who saves a cost
  # in between waits, and then finds it marked No cost. Without one
  # transaction around the whole of it, the lock would end with the read,
  # and the marking would write over a cost it never read.
  it 'makes a cook who saves a cost while it runs wait, and then the cost is marked' do
    observer = open_session
    listed = bill
    read = Queue.new
    go = Queue.new
    tries = 0
    allow(NoCostMarking).to receive(:reason_to_leave).and_wrap_original do |original, *args|
      tries += 1
      if tries == 1
        read << true
        go.pop
      end
      original.call(*args)
    end
    marking = Thread.new do
      Thread.current.report_on_exception = false
      ActiveRecord::Base.connection_pool.with_connection { NoCostMarking.call(bill_ids: [listed.id]) }
    end
    read.pop

    entering = Thread.new do
      Thread.current.report_on_exception = false
      ActiveRecord::Base.connection_pool.with_connection { Bill.find(listed.id).update!(amount: BigDecimal('12')) }
    end
    # The cook's save locks the meal first (LocksItsMealFirst).
    waited = wait_for_blocked_session(observer, 'FOR KEY SHARE')
    go << true
    result = marking.value

    expect(waited).to be(true)
    expect(result.marked).to eq([listed])
    expect { entering.join }.to raise_error(ActiveRecord::ActiveRecordError)
    expect(listed.reload).to have_attributes(amount: BigDecimal('0'), no_cost: true)
  ensure
    go&.push(true)
    marking&.join
    entering&.join rescue nil # rubocop:disable Style/RescueModifier -- its error was checked above
    observer&.close
  end

  # It locks only the dinners of the listed costs. A sign-up for another
  # dinner, one with a cost of its own, goes ahead while it runs. (The
  # marking may then fail as a conflict and try again; only its first try
  # waits here.)
  it 'does not make a write to another dinner wait' do
    other = create(:meal, community: community, date: meal.date - 1)
    create(:bill, meal: other, resident: create(:resident, community: community, unit: unit), community: community,
                  amount: BigDecimal('0'))
    person = create(:resident, community: community, unit: unit)
    listed = bill
    read = Queue.new
    go = Queue.new
    tries = 0
    allow(NoCostMarking).to receive(:reason_to_leave).and_wrap_original do |original, *args|
      tries += 1
      if tries == 1
        read << true
        go.pop
      end
      original.call(*args)
    end
    marking = Thread.new do
      Thread.current.report_on_exception = false
      ActiveRecord::Base.connection_pool.with_connection { NoCostMarking.call(bill_ids: [listed.id]) }
    end
    read.pop

    signing_up = Thread.new do
      Thread.current.report_on_exception = false
      ActiveRecord::Base.connection_pool.with_connection { MealResident.create!(meal: other, resident: person) }
    end
    finished = signing_up.join(2)
    go << true

    expect(finished).not_to be_nil
    expect(marking.value.marked).to eq([listed])
  ensure
    go&.push(true)
    marking&.join
    signing_up&.join
  end
end
