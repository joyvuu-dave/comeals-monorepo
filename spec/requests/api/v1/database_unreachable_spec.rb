# frozen_string_literal: true

require 'rails_helper'

# Through the whole middleware stack: a request that loses its database
# connection in a controller is answered 503, not 500 (DatabaseUnreachable).
RSpec.describe 'A lost database connection' do
  it 'answers an API request 503 with a Retry-After and the message' do
    allow_any_instance_of(Api::V1::SiteController) # rubocop:disable RSpec/AnyInstance -- the failure is inside the request
      .to receive(:version).and_raise(ActiveRecord::ConnectionFailed, 'server closed the connection unexpectedly')

    get '/api/v1/version'

    expect(response).to have_http_status(:service_unavailable)
    expect(response.headers['Retry-After']).to eq('5')
    expect(response.parsed_body).to eq('message' => DatabaseUnreachable::MESSAGE)
  end
end
