# frozen_string_literal: true

require 'rails_helper'

# Puma reuses its threads, and so does Solid Queue. Anything a request or a
# job leaves in thread-local state (Thread.current, or Current, which is
# built on it) is there for the next request or job on that thread — a
# resident's socket id, the community row read an hour ago, the resident
# names as they were before a rename. Rails resets Current at the edges
# of every request (ActionDispatch::Executor) and every job (the reloader
# around ActiveJob::Base.execute), and this proves it the way
# https://pawelurbanek.com/rails-thread-safety does: a few threads, each
# sending many requests in a row, every request setting every attribute
# Current has, and a probe at the start of each one that must see nothing.
#
# The probe is the start_processing.action_controller notification, which
# fires before any before_action runs, on the request's own thread. For a
# job it is perform_start.active_job.
#
# The same threads then check that what a request leaves behind cannot be
# seen through the app either: a socket id from one request never rides
# on a later request's push (LiveUpdate.meal), and a resident renamed
# between two requests on one thread is shortened under the new name in
# the second.
RSpec.describe 'thread-local state across requests and jobs on a reused thread' do
  include_context 'with no test transaction'

  # Four threads, sixty requests each; the pool below is sized for them.
  let(:thread_count) { 4 }
  let(:requests_per_thread) { 60 }
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:residents) do
    Array.new(thread_count) do |i|
      create(:resident, community: community, unit: unit, name: "Thread Person #{i}")
    end
  end
  let(:meals) { Array.new(thread_count) { |i| create(:meal, community: community, date: Date.new(2026, 4, 10 + i)) } }

  before(:all) do
    # rubocop:disable RSpec/InstanceVariable -- before(:all) has no let; the pool is process state
    @original_db_config = ActiveRecord::Base.connection_db_config.configuration_hash
    ActiveRecord::Base.establish_connection(@original_db_config.merge(pool: 8))
    Rails.application.eager_load!
    Rails.application.reload_routes_unless_loaded
  end

  after(:all) do
    ActiveRecord::Base.establish_connection(@original_db_config)
    # rubocop:enable RSpec/InstanceVariable
  end

  def request(method, path, resident, params = {})
    env = Rack::MockRequest.env_for(path, method: method.to_s.upcase, input: JSON.generate(params),
                                          'CONTENT_TYPE' => 'application/json',
                                          'HTTP_AUTHORIZATION' => "Bearer #{JwtAuth.encode(resident)}")
    status, _headers, body = Rails.application.call(env)
    text = +''
    body.each { |chunk| text << chunk }
    body.close if body.respond_to?(:close)
    [status, text]
  end

  # The probes: what Current holds at the start of a request or a job, on
  # the thread it runs on, plus whether a transaction is open there.
  def probe(events, name)
    ActiveSupport::Notifications.subscribe(name) do |*|
      events << [name, Thread.current.object_id, Current.attributes.dup,
                 ActiveRecord::Base.connection.transaction_open?]
    end
  end

  def unsubscribe(subscribers)
    subscribers.each { |s| ActiveSupport::Notifications.unsubscribe(s) }
  end

  it 'starts every request and every job with an empty Current and no open transaction' do
    residents
    meals
    events = Queue.new
    subscribers = [probe(events, 'start_processing.action_controller'), probe(events, 'perform_start.active_job')]
    pushes = Queue.new
    allow(Pusher).to receive(:trigger) { |channel, _event, _data, options = nil| pushes << [channel, options] }

    threads = Array.new(thread_count) do |t|
      Thread.new do
        resident = residents[t]
        meal = meals[t]
        requests_per_thread.times do |n|
          # Every request sets something in Current: the socket id (set_meal),
          # the community (Community.instance), the resident names (a login).
          case n % 4
          when 0 then request(:post, "/api/v1/meals/#{meal.id}/residents/#{resident.id}", resident,
                              { late: false, vegetarian: false, socket_id: "sock-#{t}-#{n}" })
          when 1 then request(:delete, "/api/v1/meals/#{meal.id}/residents/#{resident.id}", resident, {})
          when 2 then request(:post, '/api/v1/residents/token', resident,
                              { email: resident.email, password: resident.password })
          else
            # The way Solid Queue runs a job, on a thread that just served a
            # request. The ledger check only adds a row, so four at once
            # never conflict; two balance refreshes at once do.
            ActiveJob::Base.execute(VerifyLedgerJob.new.serialize)
            request(:get, "/api/v1/communities/#{community.id}/calendar/2026-04-15", resident)
          end
        end
      end
    end
    threads.each { |thread| expect(thread.join(60)).not_to be_nil, 'a thread did not finish' }
    unsubscribe(subscribers)

    seen = Array.new(events.size) { events.pop }
    expect(seen.size).to be >= thread_count * requests_per_thread
    dirty = seen.reject { |_, _, attributes, open| attributes.empty? && !open }
    expect(dirty).to be_empty, "state at the start of a request or job:\n#{dirty.first(10).map(&:inspect).join("\n")}"

    # The push for each meal must carry exactly the socket of the request
    # that wrote it: the signups (n % 4 == 0) carry their own, the leaves
    # (n % 4 == 1) sent none and so carry none.
    by_meal = Array.new(pushes.size) { pushes.pop }.group_by(&:first)
    meals.each_with_index do |meal, t|
      sockets = by_meal.fetch("meal-#{meal.id}").map { |_, options| options && options[:socket_id] }
      signups = (0...requests_per_thread).select { |n| (n % 4).zero? }
      expect(sockets.compact).to match_array(signups.map { |n| "sock-#{t}-#{n}" })
      expect(sockets.count(&:nil?)).to eq(signups.size)
    end
  end

  it 'shortens a renamed resident under the new name on the very next request of the same thread' do
    residents
    person = residents.first
    other = create(:resident, community: community, unit: unit, name: 'Thread Other')

    # One thread, two requests in a row. The first reads the names into
    # Current.resident_names; the rename happens between them.
    names = Thread.new do
      first = request(:post, '/api/v1/residents/token', person, { email: person.email, password: person.password })
      person.update!(name: 'Renamed Person')
      second = request(:post, '/api/v1/residents/token', person, { email: person.email, password: person.password })
      [first, second].map { |_, body| JSON.parse(body)['username'] }
    end.value

    # "Thread Person 0" among "Thread Person 1..3" and "Thread Other" is
    # "Thread 0"; a stale list would shorten "Renamed Person" to "Renamed P",
    # because it does not hold that name and so cannot see it is unique.
    expect(names).to eq(['Thread 0', 'Renamed'])
    expect(other).to be_persisted
  end
end
