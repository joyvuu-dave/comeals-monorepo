# frozen_string_literal: true

require 'rails_helper'

# An API request that loses its database connection is answered 503 with
# a Retry-After, not 500 (challenge 30, bin/faults).
RSpec.describe DatabaseUnreachable do
  let(:errors) { [] }
  let(:subscriber) do
    Class.new do
      def initialize(errors) = @errors = errors
      def report(error, handled:, severity:, **) = @errors << [error.class, handled, severity]
    end.new(errors)
  end

  around do |example|
    Rails.error.subscribe(subscriber)
    example.run
  ensure
    Rails.error.unsubscribe(subscriber)
  end

  def call(path, error)
    app = ->(_env) { raise error }
    described_class.new(app).call(Rack::MockRequest.env_for(path))
  end

  [ActiveRecord::ConnectionFailed.new('server closed the connection unexpectedly'),
   ActiveRecord::DatabaseConnectionError.new('There is an issue connecting with your hostname'),
   ActiveRecord::ConnectionNotEstablished.new('connection to server failed')].each do |error|
    it "answers #{error.class} on an API path with 503, a Retry-After and a message, and reports it" do
      status, headers, body = call('/api/v1/meals/1/residents/2', error)

      expect(status).to eq(503)
      expect(headers).to include('retry-after' => '5', 'content-type' => 'application/json; charset=utf-8')
      expect(JSON.parse(body.join)).to eq('message' => described_class::MESSAGE)
      expect(errors).to eq([[error.class, true, :warning]])
    end
  end

  it 'lets the error through on a path that is not the API, for the error page' do
    expect { call('/admin/meals', ActiveRecord::ConnectionFailed.new('gone')) }
      .to raise_error(ActiveRecord::ConnectionFailed)
  end

  it 'lets any other error through' do
    expect { call('/api/v1/version', ActiveRecord::RecordNotFound.new('no')) }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it 'passes an answer through untouched' do
    app = ->(_env) { [200, { 'content-type' => 'text/plain' }, ['ok']] }
    expect(described_class.new(app).call(Rack::MockRequest.env_for('/api/v1/version')))
      .to eq([200, { 'content-type' => 'text/plain' }, ['ok']])
  end

  it 'is in the middleware stack inside Bugsnag::Rack, so Bugsnag gets one handled report' do
    stack = Rails.application.middleware.map(&:klass)
    expect(stack.index(described_class)).to be > stack.index(Bugsnag::Rack)
    expect(stack.index(described_class)).to be < stack.index(Rack::Attack)
  end
end
