# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'AssetCacheControl' do
  # A fixture file with a Vite-style hashed name. The real built assets
  # are not present on CI, so the spec brings its own.
  let(:fixture) { Rails.public_path.join('assets/spec-fixture-Ab12Cd34.js') }

  before do
    fixture.dirname.mkpath
    fixture.write('// asset_cache_control_spec fixture')
  end

  after do
    fixture.delete
  end

  it 'serves /assets/ files with a year-long immutable cache header' do
    get "/assets/#{fixture.basename}"
    expect(response).to have_http_status(:ok)
    expect(response.headers['cache-control']).to eq('public, max-age=31536000, immutable')
  end

  it 'does not add the header to public files outside /assets/' do
    get '/manifest.json'
    expect(response).to have_http_status(:ok)
    expect(response.headers['cache-control'].to_s).not_to include('immutable')
  end

  it 'does not add the header when the SPA catch-all answers a missing asset' do
    get '/assets/no-such-file-Ab12Cd34.js'
    expect(response).to have_http_status(:ok)
    expect(response.content_type).to start_with('text/html')
    expect(response.headers['cache-control'].to_s).not_to include('immutable')
  end
end
