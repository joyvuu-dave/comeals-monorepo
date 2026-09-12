# frozen_string_literal: true

require 'rails_helper'

# Every connection busy for the whole checkout timeout. The server is out
# of capacity for a moment; the request itself is fine. That is a 503 with
# a Retry-After, not a 500 (RFC 9110), so a client can back off instead of
# showing an error it cannot act on.
#
# Reachable today only by a query that holds its connection for the full
# statement timeout while another thread waits — the boot check
# (DatabasePoolCheck) rules out the configuration that would make it
# common. bin/storm found it by setting the pool below the thread count,
# which the app now refuses to boot with.
RSpec.describe 'a request that cannot get a database connection' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }
  let(:meal) { create(:meal, community: community) }

  # Raised from inside the action, the way a checkout that timed out
  # arrives. The message is the one ActiveRecord uses.
  def exhaust_the_pool
    allow(Meal).to receive(:includes).and_raise(
      ActiveRecord::ConnectionTimeoutError,
      'could not obtain a connection from the pool within 5.000 seconds'
    )
  end

  it 'answers 503 with a Retry-After, not 500' do
    meal
    exhaust_the_pool

    get "/api/v1/meals/#{meal.id}/cooks", params: { token: token }

    expect(response).to have_http_status(:service_unavailable)
    expect(response.headers['Retry-After']).to eq('5')
    expect(response.parsed_body['message']).to eq(
      'The server is busy right now. Nothing was saved. Please try again in a moment.'
    )
  end

  it 'reports it, because a pool too small is something to see in Bugsnag' do
    meal
    exhaust_the_pool
    allow(Rails.error).to receive(:report).and_call_original

    get "/api/v1/meals/#{meal.id}/cooks", params: { token: token }

    expect(Rails.error).to have_received(:report)
      .with(an_instance_of(ActiveRecord::ConnectionTimeoutError), hash_including(handled: true, severity: :warning))
  end
end
