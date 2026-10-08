# frozen_string_literal: true

require 'rails_helper'

# Two bills saves with the same Idempotency-Key at the same moment: a page
# sent a save, heard nothing, and sent it again while the first try was
# still running (decision 6 of #135). Exactly one of them may write, and
# the other must be answered as already made.
#
# The meal lock puts them one after the other. That alone is not enough
# at SERIALIZABLE: the second save's snapshot is taken by its first
# statement, which is the lock it then waits for. So once it has the lock,
# it reads the table as it was before the first save committed, and does
# not see the first save's key. What stops it from writing is PostgreSQL:
# the first save changed what the second read, so the second is refused
# as a conflict, and RetryOnConflict runs it again, when it finds the key.
# If the first save wrote bills, the refusal comes at the lock, because a
# bill's write touches the meal row. If it wrote nothing (its edits were
# already done), the refusal comes when the second save inserts the same
# key: the unique index on (meal_id, key) finds the first save's row.
#
# The first save stops after it wrote its key, holding the lock, until the
# second is waiting for that lock. Without a test transaction, because the
# two saves must see each other's locks and commits. prosopite is off: a
# retry runs the same queries again on purpose.
RSpec.describe 'two bills saves with the same Idempotency-Key at the same moment', prosopite: false do
  include_context 'with no test transaction'

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:bob) { create(:resident, community: community, unit: unit, name: 'Bob') }
  let(:meal) { create(:meal, community: community, date: Date.yesterday) }

  # Everything the app reported, from any thread, so an example can say
  # which kind of refusal happened.
  let(:reports) { Queue.new }
  let(:reporter) do
    reports = self.reports
    Class.new do
      define_method(:report) { |error, **| reports << error }
    end.new
  end

  before { Rails.error.subscribe(reporter) }
  after { Rails.error.unsubscribe(reporter) }

  def reported
    Array.new(reports.size) { reports.pop }
  end

  def db_session
    db = ActiveRecord::Base.connection_db_config.configuration_hash
    PG.connect(host: db[:host], port: db[:port], user: db[:username], password: db[:password], dbname: db[:database])
  end

  # One save through the whole Rack stack, on its own thread and its own
  # connection.
  def save_in_thread(token, edits)
    Thread.new do
      env = Rack::MockRequest.env_for(
        "/api/v1/meals/#{meal.id}/bills",
        method: 'PATCH', input: JSON.generate(edits: edits), 'CONTENT_TYPE' => 'application/json',
        'HTTP_AUTHORIZATION' => "Bearer #{token}", 'HTTP_IDEMPOTENCY_KEY' => '"the-same-key"'
      )
      status, _headers, body = Rails.application.call(env)
      text = +''
      body.each { |chunk| text << chunk }
      body.close if body.respond_to?(:close)
      [status, JSON.parse(text)]
    end
  end

  # The first save to write its key stops there, inside its transaction,
  # until told to go on.
  def stop_the_first_save_after_its_key(stopped, go_on)
    first = true
    lock = Mutex.new
    allow(BillsSaveKey).to receive(:create!).and_wrap_original do |original, *args, **kwargs|
      original.call(*args, **kwargs).tap do
        stop = lock.synchronize { first.tap { first = false } }
        if stop
          stopped << true
          go_on.pop
        end
      end
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

  # Runs the two saves: the first stops after its key, the second starts
  # and waits for the meal lock, and then the first goes on and commits.
  # Returns both answers, first save first.
  def race(edits)
    token = resident.keys.first.token
    stopped = Queue.new
    go_on = Queue.new
    stop_the_first_save_after_its_key(stopped, go_on)
    # Two request threads need two connections, and the test pool has
    # two. This thread gives its own back until they are done.
    ActiveRecord::Base.connection_pool.release_connection
    session = db_session

    first = save_in_thread(token, edits)
    # With no time limit, a first save that never writes its key would
    # leave this example waiting forever instead of failing.
    expect(stopped.pop(timeout: 15)).to be(true), 'the first save never wrote its key'
    second = save_in_thread(token, edits)
    waited = someone_waits?(session)
    go_on << true

    answers = [first, second].map { |thread| thread.join(15)&.value }
    expect(waited).to be(true), 'the second save never waited for the meal lock'
    answers
  ensure
    session&.close
  end

  def change_bob(from, to)
    [{ op: 'change', resident_id: bob.id, from: { amount: from, no_cost: false }, to: { amount: to, no_cost: false } }]
  end

  def bill_audits
    meal.associated_audits.where(auditable_type: 'Bill')
  end

  it 'writes the bills once, and answers the second save as already made, when the first wrote bills' do
    bill = create(:bill, meal: meal, resident: bob, community: community, amount: BigDecimal('5'))
    audits = bill_audits.count

    answers = race(change_bob('5.0', '7.00'))

    expect(answers.map { |status, body| [status, body['type']] }).to eq([[200, nil], [200, 'replayed']])
    expect(bill.reload.amount).to eq(BigDecimal('7'))
    expect(bill_audits.count).to eq(audits + 1)
    expect(BillsSaveKey.where(meal_id: meal.id).count).to eq(1)
    expect(reported).to include(an_instance_of(ActiveRecord::SerializationFailure))
  end

  # The case only the unique index catches: the first save wrote no bill,
  # so it did not touch the meal row, and the second save gets the lock
  # with no refusal and does not see the first save's key.
  it 'keeps one key, and answers the second save as already made, when the first wrote no bills' do
    create(:bill, meal: meal, resident: bob, community: community, amount: BigDecimal('7'))

    answers = race(change_bob('5.0', '7.00'))

    expect(answers.map { |status, body| [status, body['type']] }).to eq([[200, nil], [200, 'replayed']])
    expect(BillsSaveKey.where(meal_id: meal.id).count).to eq(1)
    expect(reported).to include(an_instance_of(ActiveRecord::SerializationFailure))
  end
end
