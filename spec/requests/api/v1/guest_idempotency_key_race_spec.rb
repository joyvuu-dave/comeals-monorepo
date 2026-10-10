# frozen_string_literal: true

require 'rails_helper'

# Two guest adds with the same Idempotency-Key at the same moment: the
# page sent an add, heard nothing, and the person tapped again while the
# first add was still running (S2). Exactly one of them may add a guest,
# and the other must be answered as already done.
#
# The meal lock puts them one after the other. That alone is not enough
# at SERIALIZABLE: the second add's snapshot is taken by its first
# statement, which is the lock it then waits for. So once it has the lock,
# it reads the table as it was before the first add committed, and does
# not see the first add's key. What stops it from adding is PostgreSQL:
# the first add's guest touched the meal row the second locked, so the
# second is refused as a conflict, and RetryOnConflict runs it again, when
# it finds the key. A guest add always writes a guest, so unlike a bills
# save there is no add that writes only its key.
#
# The first add stops after it wrote its key, holding the lock, until the
# second is waiting for that lock. Without a test transaction, because the
# two adds must see each other's locks and commits. prosopite is off: a
# retry runs the same queries again on purpose.
RSpec.describe 'two guest adds with the same Idempotency-Key at the same moment', prosopite: false do
  include_context 'with no test transaction'

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:meal) { create(:meal, community: community, date: Date.tomorrow) }

  # Everything the app reported, from any thread, so the example can say
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

  # One add through the whole Rack stack, on its own thread and its own
  # connection.
  def add_in_thread(token)
    Thread.new do
      env = Rack::MockRequest.env_for(
        "/api/v1/meals/#{meal.id}/residents/#{resident.id}/guests",
        method: 'POST', input: JSON.generate(vegetarian: false), 'CONTENT_TYPE' => 'application/json',
        'HTTP_AUTHORIZATION' => "Bearer #{token}", 'HTTP_IDEMPOTENCY_KEY' => '"the-same-key"'
      )
      status, _headers, body = Rails.application.call(env)
      text = +''
      body.each { |chunk| text << chunk }
      body.close if body.respond_to?(:close)
      [status, JSON.parse(text)]
    end
  end

  # The first add to write its key stops there, inside its transaction,
  # until told to go on.
  def stop_the_first_add_after_its_key(stopped, go_on)
    first = true
    lock = Mutex.new
    allow(GuestAddKey).to receive(:create!).and_wrap_original do |original, *args, **kwargs|
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

  # Runs the two adds: the first stops after its key, the second starts
  # and waits for the meal lock, and then the first goes on and commits.
  # Returns both answers, first add first.
  def race
    token = resident.keys.first.token
    stopped = Queue.new
    go_on = Queue.new
    stop_the_first_add_after_its_key(stopped, go_on)
    # Two request threads need two connections, and the test pool has
    # two. This thread gives its own back until they are done.
    ActiveRecord::Base.connection_pool.release_connection
    session = db_session

    first = add_in_thread(token)
    # With no time limit, a first add that never writes its key would
    # leave this example waiting forever instead of failing.
    expect(stopped.pop(timeout: 15)).to be(true), 'the first add never wrote its key'
    second = add_in_thread(token)
    waited = someone_waits?(session)
    go_on << true

    answers = [first, second].map { |thread| thread.join(15)&.value }
    expect(waited).to be(true), 'the second add never waited for the meal lock'
    answers
  ensure
    session&.close
  end

  it 'adds one guest, and answers the second add as already done, with that guest' do
    answers = race

    guest = meal.guests.sole
    expect(answers.map { |status, body| [status, body['type']] }).to eq([[200, nil], [200, 'replayed']])
    expect(answers.first.last['id']).to eq(guest.id)
    expect(answers.last.last['guest']['id']).to eq(guest.id)
    expect(GuestAddKey.where(meal_id: meal.id).count).to eq(1)
    expect(reported).to include(an_instance_of(ActiveRecord::SerializationFailure))
  end
end
