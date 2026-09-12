# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'AssetCacheControl' do
  # A fixture file with a Vite-style hashed name. The real built assets
  # are not present on CI, so the spec brings its own. The name carries
  # the process id, because mutant runs this file in several processes
  # at once and one process must not delete another's fixture.
  let(:fixture) { Rails.public_path.join("assets/spec-fixture-#{Process.pid}-Ab12Cd34.js") }

  # The SPA page exists only after a build. Bring one when it is
  # missing, and leave it: a later build overwrites it, and deleting it
  # would race the other processes that also found it missing.
  let(:index) { Rails.public_path.join('index.html') }

  before do
    fixture.dirname.mkpath
    fixture.write('// asset_cache_control_spec fixture')
    index.write('<!doctype html><title>Comeals</title><div id="root"></div>') unless index.exist?
  end

  after do
    fixture.delete
  end

  it 'serves /assets/ files with a year-long immutable cache header, and the file itself' do
    get "/assets/#{fixture.basename}"
    expect(response).to have_http_status(:ok)
    expect(response.headers['cache-control']).to eq('public, max-age=31536000, immutable')
    expect(response.body).to eq('// asset_cache_control_spec fixture')
  end

  it 'serves /vite-assets/ files with the same header' do
    vite_fixture = Rails.public_path.join("vite-assets/spec-fixture-#{Process.pid}-Cd34Ef56.js")
    vite_fixture.dirname.mkpath
    vite_fixture.write('// vite fixture')

    get "/vite-assets/#{vite_fixture.basename}"
    expect(response).to have_http_status(:ok)
    expect(response.headers['cache-control']).to eq('public, max-age=31536000, immutable')
  ensure
    vite_fixture&.delete
  end

  it 'leaves public files outside /assets/ with the static server\'s own header' do
    get '/manifest.json'
    expect(response).to have_http_status(:ok)
    expect(response.headers['cache-control'].to_s).not_to include('immutable')
    expect(response.headers['cache-control']).not_to eq('no-cache')
  end

  it 'does not add the header when the SPA catch-all answers a missing asset' do
    get '/assets/no-such-file-Ab12Cd34.js'
    expect(response).to have_http_status(:ok)
    expect(response.content_type).to start_with('text/html')
    expect(response.headers['cache-control'].to_s).not_to include('immutable')
  end

  it 'serves /service-worker.js with no-cache, so old browsers revalidate it' do
    get '/service-worker.js'
    expect(response).to have_http_status(:ok)
    expect(response.headers['cache-control']).to eq('no-cache')
  end

  describe '/.vite/manifest.json' do
    # The real manifest exists only after a build. Bring one when it is
    # missing, and leave a real one alone.
    let(:manifest) { Rails.public_path.join('.vite/manifest.json') }
    let!(:wrote_fixture) do
      next false if manifest.exist?

      manifest.dirname.mkpath
      manifest.write('{"index.html":{"file":"vite-assets/index-spec.js","isEntry":true}}')
      true
    end

    after { manifest.delete if wrote_fixture }

    it 'is served by the static file server with no-cache, so the version banner sees a deploy' do
      get '/.vite/manifest.json'
      expect(response).to have_http_status(:ok)
      expect(response.content_type).to start_with('application/json')
      expect(response.headers['cache-control']).to eq('no-cache')
      expect(response.headers).not_to have_key('x-runtime'), 'the static server, not a controller, should answer'
    end
  end
end
