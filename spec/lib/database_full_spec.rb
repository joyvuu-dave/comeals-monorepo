# frozen_string_literal: true

require 'rails_helper'

# An API request refused because the database's disk is full is answered
# 507 with a message, not 500 (challenge 30).
RSpec.describe DatabaseFull do
  def call(path, error)
    app = ->(_env) { raise error }
    described_class.new(app).call(Rack::MockRequest.env_for(path))
  end

  # ActiveRecord raises StatementInvalid with the driver's error as its
  # cause, the way the PostgreSQL adapter does.
  def statement_invalid_from(driver_error)
    raise driver_error
  rescue PG::Error
    begin
      raise ActiveRecord::StatementInvalid, driver_error.message
    rescue ActiveRecord::StatementInvalid => e
      e
    end
  end

  let(:disk_full) { statement_invalid_from(PG::DiskFull.new('could not extend file: No space left on device')) }

  it 'answers a full disk on an API path with 507 and the message, with no Retry-After' do
    status, headers, body = call('/api/v1/meals/1/residents/2', disk_full)

    expect(status).to eq(507)
    expect(headers).to eq('content-type' => 'application/json; charset=utf-8')
    expect(JSON.parse(body.join)).to eq('message' => described_class::MESSAGE)
  end

  it 'reports the error as handled, as an error, with the path' do
    allow(Rails.error).to receive(:report)

    call('/api/v1/meals/1/residents/2', disk_full)

    expect(Rails.error).to have_received(:report)
      .with(disk_full, handled: true, severity: :error, context: { path: '/api/v1/meals/1/residents/2' })
  end

  it 'lets a full disk through on a path that is not the API, for the error page' do
    expect { call('/admin/meals', disk_full) }.to raise_error(disk_full)
  end

  it 'lets a statement error with another cause through' do
    other = statement_invalid_from(PG::OutOfMemory.new('out of memory'))
    expect { call('/api/v1/version', other) }.to raise_error(other)
  end

  it 'lets a statement error with no cause through' do
    expect { call('/api/v1/version', ActiveRecord::StatementInvalid.new('no')) }
      .to raise_error(ActiveRecord::StatementInvalid)
  end

  it 'passes an answer through untouched' do
    app = ->(_env) { [200, { 'content-type' => 'text/plain' }, ['ok']] }
    expect(described_class.new(app).call(Rack::MockRequest.env_for('/api/v1/version')))
      .to eq([200, { 'content-type' => 'text/plain' }, ['ok']])
  end

  it 'is in the middleware stack inside Bugsnag::Rack and outside Rack::Attack' do
    stack = Rails.application.middleware.map(&:klass)
    expect(stack.index(described_class)).to be > stack.index(Bugsnag::Rack)
    expect(stack.index(described_class)).to be < stack.index(Rack::Attack)
  end
end
