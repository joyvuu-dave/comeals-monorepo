# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'AssetCacheControl' do
  # A fixture file with a Vite-style hashed name. The real built assets
  # are not present on CI, so the spec brings its own. The name carries
  # the process id, because mutant runs this file in several processes
  # at once and one process must not delete another's fixture.
  let(:fixture) { Rails.public_path.join("assets/spec-fixture-#{Process.pid}-Ab12Cd34.js") }

  before do
    fixture.dirname.mkpath
    fixture.write('// asset_cache_control_spec fixture')
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

  it 'answers a missing asset with a 404 that is not marked to be cached' do
    get '/assets/no-such-file-Ab12Cd34.js'
    expect(response).to have_http_status(:not_found)
    expect(response.headers['cache-control'].to_s).not_to include('immutable')
  end

  it 'serves /service-worker.js with no-cache, so old browsers revalidate it' do
    get '/service-worker.js'
    expect(response).to have_http_status(:ok)
    expect(response.headers['cache-control']).to eq('no-cache')
  end

  describe '/.vite/manifest.json' do
    # The real manifest exists only after a build. Bring one when it is
    # missing, leave a real one alone, and never delete it: mutant runs
    # this file in several processes at once, and one deleting the file
    # would make another's request miss it. A later build overwrites it.
    # spec/support/spa_page.rb does the same for index.html.
    let(:manifest) { Rails.public_path.join('.vite/manifest.json') }

    before do
      next if manifest.exist?

      manifest.dirname.mkpath
      manifest.write('{"index.html":{"file":"vite-assets/index-spec.js","isEntry":true}}')
    end

    it 'is served by the static file server with no-cache, so the version banner sees a deploy' do
      get '/.vite/manifest.json'
      expect(response).to have_http_status(:ok)
      expect(response.content_type).to start_with('application/json')
      expect(response.headers['cache-control']).to eq('no-cache')
      expect(response.headers).not_to have_key('x-runtime'), 'the static server, not a controller, should answer'
    end
  end

  # The middleware on its own, around a stand-in app, for answers the real
  # stack does not give on demand. The request examples above also never
  # run #initialize: Rails builds the middleware once, at boot.
  describe 'around a stand-in app' do
    def answer(path, status, headers)
      app = ->(_env) { [status, headers, ['body']] }
      AssetCacheControl.new(app).call(Rack::MockRequest.env_for(path))
    end

    let(:year) { 'public, max-age=31536000, immutable' }

    it "passes the app's answer on, with the header added" do
      expect(answer('/assets/app-Ab12Cd34.js', 200, { 'content-type' => 'text/javascript' }))
        .to eq([200, { 'content-type' => 'text/javascript', 'cache-control' => year }, ['body']])
    end

    # During a deploy an old dyno can answer 404 for a new asset. Cached for
    # a year, that answer would outlive the deploy that mends it.
    it 'does not mark an error under the asset paths as cacheable' do
      expect(answer('/assets/app-Ab12Cd34.js', 404, { 'content-type' => 'text/javascript' })[1])
        .not_to have_key('cache-control')
      expect(answer('/vite-assets/app-Ab12Cd34.js', 500, { 'content-type' => 'text/javascript' })[1])
        .not_to have_key('cache-control')
    end

    it 'leaves an error at a path that must be revalidated alone' do
      expect(answer('/service-worker.js', 404, {})[1]).not_to have_key('cache-control')
    end

    it 'does not cache the app page when its content type names a charset' do
      expect(answer('/assets/gone-Ab12Cd34.js', 200, { 'content-type' => 'text/html; charset=utf-8' })[1])
        .not_to have_key('cache-control')
    end

    it 'caches an asset whose answer names no content type' do
      expect(answer('/assets/app-Ab12Cd34.js', 200, {})[1]).to eq({ 'cache-control' => year })
    end
  end
end
