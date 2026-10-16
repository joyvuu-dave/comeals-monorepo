# frozen_string_literal: true

require 'rails_helper'

# An admin write and an API write on the same meal at the same moment.
#
# The API holds the meal row and then writes a child row
# (Api::V1::MealsController#with_meal_lock). An admin write used to go the
# other way round: it wrote the child row, which took that row's lock, and
# the settled-meal trigger then asked for the meal from inside that write.
# Two lock orders on one pair of rows is a deadlock, and a request storm
# found it (docs/concurrency-testing.md): an admin bill edit held the bill
# and waited for the meal while an API bills save held the meal and waited
# for that bill. PostgreSQL broke it after a second and one side was told
# to try again.
#
# LocksItsMealFirst locks the meal before the row, so both paths now lock
# meal first, row second. An admin write waits for the API's write, and
# then is refused as a conflict ("try again"), whichever row the API
# wrote: the API's write changed the meal row, and the admin request's
# SERIALIZABLE snapshot is older than that change. A write through the
# models changes the meal row with `touch: true`, and since
# 20261016120000 the child-write trigger changes it too, so the API side
# below, which writes raw SQL, changes it the same way the real API does.
# What one lock order buys is that this is a wait and one conflict,
# never a deadlock: no example may ever see ActiveRecord::Deadlocked.
#
# The API's side is a session of its own: it holds the meal the way the
# API does, waits until the admin request is waiting on a lock, writes,
# and commits. Without a test transaction, because the two sessions must
# see each other's locks.
RSpec.describe 'the lock order of an admin write against an API write on the same meal' do
  include_context 'with no test transaction'

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:admin_user) { create(:admin_user, community: community, superuser: true) }
  let(:cook) { create(:resident, community: community, unit: unit) }
  let(:other) { create(:resident, community: community, unit: unit) }
  let(:meal) { create(:meal, community: community) }

  # Everything the app reported, from any thread, so an example can say
  # which kind of refusal happened rather than only that one did.
  let(:reports) { Queue.new }
  let(:reporter) do
    reports = self.reports
    Class.new do
      define_method(:report) { |error, **| reports << error }
    end.new
  end

  before do
    host! 'admin.example.com'
    sign_in admin_user
    Rails.error.subscribe(reporter)
  end

  after { Rails.error.unsubscribe(reporter) }

  def reported
    Array.new(reports.size) { reports.pop }
  end

  def db_session
    db = ActiveRecord::Base.connection_db_config.configuration_hash
    PG.connect(host: db[:host], port: db[:port], user: db[:username], password: db[:password], dbname: db[:database])
  end

  # Holds the meal, waits until another session is waiting on a lock, runs
  # the write, commits. Reports each step through the queue.
  def api_side(meal_id, statement, binds, outcome)
    Thread.new do
      session = db_session
      session.exec('BEGIN')
      session.exec_params('SELECT id FROM meals WHERE id = $1 FOR UPDATE', [meal_id])
      outcome << :locked
      outcome << :nobody_waited unless someone_waits?(session)
      session.exec_params(statement, binds)
      session.exec('COMMIT')
      outcome << :committed
    rescue PG::Error => e
      outcome << "#{e.class}: #{e.message}"
    ensure
      session&.close
    end
  end

  # True once some other session is waiting on a lock. Polled rather than
  # slept on: a fixed sleep would be either slow or flaky.
  def someone_waits?(session)
    250.times do
      waiting = session.exec('SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() ' \
                             "AND wait_event_type = 'Lock' AND pid <> pg_backend_pid()").getvalue(0, 0).to_i
      return true if waiting.positive?

      sleep 0.02
    end
    false
  end

  def finish(thread, outcome)
    expect(thread.join(15)).not_to be_nil, 'the API side did not finish'
    Array.new(outcome.size) { outcome.pop }
  end

  # This is the case the storm deadlocked on: both write the same bill.
  it 'refuses an admin bill edit as a conflict, without a deadlock, when the API rewrote that bill' do
    bill = create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('10'))
    outcome = Queue.new
    api = api_side(meal.id, 'UPDATE bills SET amount = 99 WHERE id = $1', [bill.id], outcome)
    expect(outcome.pop).to eq(:locked)

    patch "/bills/#{bill.id}", params: { bill: { amount: '5.00' } }

    expect(finish(api, outcome)).to eq([:committed])
    expect(response).to redirect_to(admin_root_path)
    expect(flash[:alert]).to include('Someone else was changing this at the same time')
    # The API's write stands; the admin was told nothing was saved, and
    # nothing was.
    expect(bill.reload.amount).to eq(BigDecimal('99'))
    # One read of the queue: `reported` empties it. Exactly one report,
    # and it is the conflict, so no deadlock was reported next to it.
    expect(reported).to contain_exactly(an_instance_of(ActiveRecord::SerializationFailure))
  end

  # The common case: two people editing one meal's different rows. The
  # admin edit waits for the API, then is told to try again, because the
  # API's write changed the meal row. Before 20261016120000 a raw write
  # here left the meal row as it was, and this example said the admin edit
  # then applied; the real API's write, which touches the meal, never
  # allowed that.
  it 'refuses an admin bill edit as a conflict, without a deadlock, when the API wrote another bill' do
    bill = create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('10'))
    others_bill = create(:bill, meal: meal, resident: other, community: community, amount: BigDecimal('20'))
    outcome = Queue.new
    api = api_side(meal.id, 'UPDATE bills SET amount = 99 WHERE id = $1', [others_bill.id], outcome)
    expect(outcome.pop).to eq(:locked)

    patch "/bills/#{bill.id}", params: { bill: { amount: '5.00' } }

    expect(finish(api, outcome)).to eq([:committed])
    expect(response).to redirect_to(admin_root_path)
    expect(flash[:alert]).to include('Someone else was changing this at the same time')
    expect(bill.reload.amount).to eq(BigDecimal('10'))
    expect(others_bill.reload.amount).to eq(BigDecimal('99'))
    expect(reported).to contain_exactly(an_instance_of(ActiveRecord::SerializationFailure))
  end

  it 'refuses an admin attendance removal as a conflict, without a deadlock, when the API wrote a bill' do
    row = create(:meal_resident, meal: meal, resident: cook, community: community)
    bill = create(:bill, meal: meal, resident: other, community: community, amount: BigDecimal('20'))
    outcome = Queue.new
    api = api_side(meal.id, 'UPDATE bills SET amount = 99 WHERE id = $1', [bill.id], outcome)
    expect(outcome.pop).to eq(:locked)

    delete "/meals/#{meal.id}/meal_residents/#{row.id}"

    expect(finish(api, outcome)).to eq([:committed])
    expect(response).to redirect_to(admin_root_path)
    expect(flash[:alert]).to include('Someone else was changing this at the same time')
    expect(MealResident.exists?(row.id)).to be(true)
    expect(bill.reload.amount).to eq(BigDecimal('99'))
    expect(reported).to contain_exactly(an_instance_of(ActiveRecord::SerializationFailure))
  end
end
