# frozen_string_literal: true

require 'rails_helper'

# The login and the password-reset request each have a throttle of their
# own in config/initializers/rack_attack.rb: 20 logins in 5 minutes and
# 10 reset requests in an hour, from one IP address. ADR 0010 relies on
# both. Each throttle counts one path. These check that the action behind
# it is reached no more often than its throttle allows, whatever the
# path's spelling, here with a format at the end. (A slash at the end, or
# two slashes in a row, needs no check: Rack::Attack takes those out of
# the path before the throttles read it. Checked by running it,
# 2026-10-16.)
RSpec.describe 'Rack::Attack throttles, for other spellings of the path' do
  include ActiveSupport::Testing::TimeHelpers

  # The same clock and store as rack_attack_spec.rb: one second after an
  # hour starts, which starts a period of every throttle here.
  before { travel_to(Time.utc(2026, 4, 1, 12, 0, 1)) }

  let(:memory_cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:login_answer) { 'No resident with email nobody@example.com' }
  let(:reset_answer) { 'No resident with that email address.' }

  around do |example|
    original = Rack::Attack.cache.store
    Rack::Attack.cache.store = memory_cache
    Rack::Attack.reset!
    example.run
    Rack::Attack.cache.store = original
  end

  def login(path)
    post path, params: { email: 'nobody@example.com', password: 'wrong' }, env: { 'REMOTE_ADDR' => '10.0.0.1' }
  end

  def reset(path)
    post path, params: { email: 'nobody@example.com' }, env: { 'REMOTE_ADDR' => '10.0.0.1' }
  end

  # Whether the last request got the action's own answer.
  def answered_with?(message)
    response.media_type == 'application/json' && response.parsed_body['message'] == message
  end

  it 'checks for the answer the login and the reset request give' do
    login('/api/v1/residents/token')
    expect(answered_with?(login_answer)).to be(true)
    reset('/api/v1/residents/password-reset')
    expect(answered_with?(reset_answer)).to be(true)
  end

  %w[/api/v1/residents/token.json /api/v1/residents/token.xml].each do |path|
    it "lets at most 20 logins in 5 minutes reach the login, sent to #{path}" do
      reached = Array.new(25) do
        login(path)
        answered_with?(login_answer)
      end

      expect(reached.count(true)).to be <= 20
    end
  end

  %w[/api/v1/residents/password-reset.json /api/v1/residents/password-reset.xml].each do |path|
    it "lets at most 10 reset requests in an hour reach the reset, sent to #{path}" do
      reached = Array.new(15) do
        reset(path)
        answered_with?(reset_answer)
      end

      expect(reached.count(true)).to be <= 10
    end
  end
end
