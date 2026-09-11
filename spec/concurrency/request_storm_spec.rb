# frozen_string_literal: true

require 'rails_helper'

# The whole API under a storm of concurrent requests, in one process,
# with the nightly jobs, a settlement, and an admin writing beside it.
#
# This is the request-level counterpart of spec/db/meal_write_storm_spec.rb.
# That one drives the models the way the controller does; this one sends
# real requests through the whole Rack stack — Rack::Attack counting in a
# real solid_cache, the executor resetting Current, the controllers,
# RetryOnConflict, LiveUpdate's pushes — from many threads at once, the
# way a multi-threaded Puma would (production runs one thread; this runs
# many on purpose, to find what one thread hides).
#
# The techniques are the ones in https://pawelurbanek.com/rails-thread-safety:
# hit the app with N concurrent requests and check that every answer is
# the answer for that request, that no state from one request reaches
# another, and that no read-then-write loses an update.
#
# What must hold:
#   - every request got a status the API promises for it, never a 500 or
#     an unrescued exception;
#   - every answer belongs to its request (/residents/id, the login);
#   - every 429 had grounds: the client's own count in that window was
#     over the limit, so the counter never held someone else's requests;
#   - every meal push carries a socket id that was sent with a write to
#     that meal, so Current.socket_id never leaked between requests;
#   - every error the app reported and swallowed is a conflict, the one
#     kind a SERIALIZABLE app is meant to swallow (RetryOnConflict,
#     solid_cache's failsafe);
#   - the settler, the jobs, and the admin never hit anything but their
#     expected refusals;
#   - the rows and the ledger are right after (Storm::Checks);
#   - the storm actually happened: writes went through, and a settlement
#     won while they did.
#
# Knobs, for turning it up: STORM_SECONDS (15), STORM_CLIENTS (24),
# STORM_SEED (1). Every client thread needs a connection, so the pool is
# widened for this group; Postgres allows 100 by default.
RSpec.describe 'a request storm against the whole API, with the nightly jobs and a settlement in it' do
  include_context 'with no test transaction'

  before(:all) do
    # rubocop:disable RSpec/InstanceVariable -- before(:all) has no let; the pool is process state
    @original_db_config = ActiveRecord::Base.connection_db_config.configuration_hash
    ActiveRecord::Base.establish_connection(@original_db_config.merge(pool: Storm.knob(:clients, 24) + 8))
    # Production eager loads: every class and every route is there before
    # the first request. The test environment loads both lazily, on the
    # first request that needs them, and many first requests at once race
    # that load — the first storm answered "No route matches" for routes
    # that exist. That race is Rails' in development and test only, so it
    # is taken off the table here.
    Rails.application.eager_load!
    Rails.application.reload_routes_unless_loaded
  end

  after(:all) do
    ActiveRecord::Base.establish_connection(@original_db_config)
    # rubocop:enable RSpec/InstanceVariable
  end

  # The test environment caches to :null_store. Production counts throttle
  # hits and caches the calendar in solid_cache, in the same database as
  # the money rows, at SERIALIZABLE — so that is what the storm gets.
  around do |example|
    store = build_solid_cache_store(namespace: "storm-#{SecureRandom.hex(4)}")
    original_cache = Rails.cache
    original_attack_store = Rack::Attack.cache.store
    original_level = Rails.logger.level
    Rails.cache = store
    Rack::Attack.cache.store = store
    # Thousands of requests: the log lines would be most of the work.
    Rails.logger.level = Logger::WARN
    example.run
  ensure
    Rails.logger.level = original_level
    Rack::Attack.cache.store = original_attack_store
    Rails.cache = original_cache
  end

  let(:seconds) { Storm.knob(:seconds, 15) }
  let(:clients) { Storm.knob(:clients, 24) }
  let(:seed) { Storm.knob(:seed, 1) }

  # A request through the whole middleware stack, on the calling thread.
  # Not wrapped in the executor: the ActionDispatch::Executor middleware
  # does that per request, and wrapping the thread would make its reset a
  # no-op — the very thing under test.
  let(:transport) do
    lambda do |method, path, headers, body, ip|
      env = Rack::MockRequest.env_for(path, method: method.to_s.upcase, input: body.to_s,
                                            'CONTENT_TYPE' => 'application/json', 'REMOTE_ADDR' => ip)
      headers.each { |name, value| env["HTTP_#{name.upcase.tr('-', '_')}"] = value }
      status, _headers, response = Rails.application.call(env)
      chunks = +''
      response.each { |chunk| chunks << chunk }
      response.close if response.respond_to?(:close)
      [status, chunks]
    end
  end

  # Everything the app reported through Rails.error, from any thread, with
  # whether it was swallowed (handled: true — RetryOnConflict, LiveUpdate's
  # push, solid_cache's failsafe) or re-raised (handled: false — the
  # executor reports what it re-raises, and the thread that raised it has
  # already judged it).
  let(:reports) { Queue.new }
  let(:reporter) do
    reports = self.reports
    Class.new do
      define_method(:report) { |error, handled:, **| reports << [error, handled] }
    end.new
  end

  before { Rails.error.subscribe(reporter) }

  after { Rails.error.unsubscribe(reporter) }

  def push_problems(pushes, meal_sockets)
    Array.new(pushes.size) { pushes.pop }.filter_map do |channel, options|
      meal_id = channel[/\Ameal-(\d+)\z/, 1]&.to_i
      socket = options && options[:socket_id]
      next if meal_id.nil? || socket.nil? || meal_sockets.include?([meal_id, socket])

      "push for #{channel} carried #{socket}, which no write to that meal sent (Current.socket_id leaked?)"
    end
  end

  # A swallowed error that is not a conflict is a problem: something went
  # wrong and nobody was told.
  def report_problems(reported)
    reported.filter_map do |error, handled|
      next if !handled || error.is_a?(ActiveRecord::TransactionRollbackError)

      "reported and swallowed: #{error.class}: #{error.message[0, 300]}"
    end.uniq
  end

  def describe_run(result, reports_tally)
    lines = result.tally.sort.map { |action, statuses| "  #{action}: #{statuses.sort_by { |s, _| s.to_s }.to_h}" }
    "requests: #{result.requests.size}, ok writes: #{result.ok_writes}, settlements: #{result.settlements}\n" \
      "#{lines.join("\n")}\nbackground: #{result.background_tally}\nreported: #{reports_tally}"
  end

  it "answers every request the way the API promises, keeps every request's state to itself, " \
     'and the books are right after' do
    plan = Storm::Seed.plant(clients: clients)
    pushes = Queue.new
    allow(Pusher).to receive(:trigger) { |channel, _event, _data, options = nil| pushes << [channel, options] }

    result = Storm::Run.call(plan: plan, transport: transport, clients: clients, seconds: seconds, seed: seed)

    problems = result.requests.filter_map { |e| e.problem && "client #{e.client} ##{e.n} #{e.action}: #{e.problem}" }
    problems += result.problems
    problems += push_problems(pushes, result.meal_sockets)
    reported = Array.new(reports.size) { reports.pop }
    problems += report_problems(reported)
    problems += Storm::Checks.call(plan: plan, transport: transport)

    summary = describe_run(result, reported.map do |e, handled|
      "#{e.class} (#{handled ? 'swallowed' : 'raised'})"
    end.tally)
    RSpec.configuration.reporter.message(summary) if ENV['STORM_TALLY']
    expect(problems.uniq).to be_empty, "#{problems.uniq.first(30).join("\n")}\n\n#{summary}"
    expect(result.ok_writes).to be >= clients * 5, summary
    expect(result.settlements).to be >= 1, summary
  end
end
