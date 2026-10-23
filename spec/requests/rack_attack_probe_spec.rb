# frozen_string_literal: true

require 'rails_helper'

# Scanners ask for files that would hold secrets if a site left them in
# its web folder: /.env, /.git/config, /.aws/credentials, /wp-admin,
# /phpinfo.php. This app has none of those, and no person using it ever
# asks for one. So config/initializers/rack_attack.rb refuses each such
# request with a 403 before it reaches the router. The rule reads only
# the path: it bans no address and keeps no count, because many residents
# share one address (a phone carrier, the common house wifi), and a ban
# would lock them all out because of one scanner.
RSpec.describe 'Rack::Attack refuses requests for secret files' do
  let(:memory_cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:scanner) { { 'REMOTE_ADDR' => '10.0.0.9' } }
  let(:someone_else) { { 'REMOTE_ADDR' => '10.0.0.10' } }

  # A real store, so a spec would see a count or a ban if the rule kept
  # one. The test environment's own store is a null store, which keeps
  # nothing.
  around do |example|
    original = Rack::Attack.cache.store
    Rack::Attack.cache.store = memory_cache
    example.run
  ensure
    Rack::Attack.cache.store = original
  end

  # The request's answer, or :no_route when the router found nothing.
  # The test environment raises for that; production answers 404.
  def status_of(path, host: 'www.example.com', env: someone_else)
    host! host
    get path, env: env
    response.status
  rescue ActionController::RoutingError
    :no_route
  end

  it 'has the rule' do
    expect(Rack::Attack.blocklists.keys).to include('secret-file-probe')
  end

  [
    '/.env', '/.git/config', '/.aws/credentials', '/.claude/settings.json', '/.ssh/id_rsa',
    '/app/.env', '/backend/.git/HEAD', '/../etc/passwd',
    '/wp-admin', '/wp-admin/setup-config.php', '/blog/wp-login.php', '/wp-content/x', '/wp-includes/x',
    '/phpinfo.php', '/login.php', '/index.PHP', '/x.php/y'
  ].each do |path|
    it "refuses #{path} with a 403, on the app host and the admin host" do
      expect(status_of(path)).to eq(403)
      expect(status_of(path, host: 'admin.example.com')).to eq(403)
    end
  end

  it 'refuses every probe from one address, and still answers its next normal request' do
    %w[/.env /.git/config /wp-login.php /.aws/credentials /phpinfo.php /.ssh/id_rsa].each do |path|
      expect(status_of(path, env: scanner)).to eq(403)
    end

    expect(status_of('/', env: scanner)).to eq(200)
    expect(status_of('/api/v1/version', env: scanner)).to eq(200)
    expect(status_of('/login', host: 'admin.example.com', env: scanner)).to eq(200)
  end

  it 'reads and writes no cache for a probe or for a normal page' do
    %i[read fetch write increment].each { |name| allow(memory_cache).to receive(name).and_call_original }

    status_of('/.env', env: scanner)
    status_of('/', env: scanner)
    status_of('/login', host: 'admin.example.com', env: scanner)

    %i[read fetch write increment].each { |name| expect(memory_cache).not_to have_received(name) }
  end

  # Paths a person, a browser or this app asks for. Each must get the
  # answer it got before the rule, from every address, however often.
  describe 'paths that must keep working' do
    it 'serves the version banner manifest, the one dotfile path the app has' do
      Rails.public_path.join('.vite').mkpath
      manifest = Rails.public_path.join('.vite/manifest.json')
      written = !manifest.exist?
      manifest.write('{}') if written

      4.times { expect(status_of('/.vite/manifest.json', env: scanner)).to eq(200) }
      expect(status_of('/', env: scanner)).to eq(200)
    ensure
      manifest.delete if written
    end

    it 'does not count /.well-known/ paths, which browsers and password managers ask for' do
      %w[/.well-known/change-password /.well-known/appspecific/com.chrome.devtools.json
         /.well-known/apple-app-site-association /.well-known/acme-challenge/abc].each do |path|
        expect(status_of(path, env: scanner)).not_to eq(403)
      end
      expect(status_of('/', env: scanner)).to eq(200)
    end

    it 'leaves the app pages, the API and the admin pages alone' do
      expect(status_of('/', env: scanner)).to eq(200)
      expect(status_of('/calendar/all/2026-04-01', env: scanner)).to eq(200)
      expect(status_of('/meals/1/edit', env: scanner)).to eq(200)
      expect(status_of('/reset-password/AbC-dEf_123', env: scanner)).to eq(200)
      expect(status_of('/api/v1/version', env: scanner)).to eq(200)
      expect(status_of('/login', host: 'admin.example.com', env: scanner)).to eq(200)
      expect(status_of('/', env: scanner)).to eq(200)
    end

    it 'takes the browser check report' do
      host! 'www.example.com'
      post '/api/v1/browser-reports', env: scanner

      expect(response).not_to have_http_status(:forbidden)
    end
  end

  # The path test alone, for names that are near the rule on either side.
  describe SecretFileProbe do
    it 'matches a path segment that starts with a dot, and the PHP and WordPress names' do
      %w[/.env /a/.git /.. /wp-admin /wp-admin/ /x/wp-login.php /a.php /a.Php/b
         /wp-content /wp-includes/a].each do |path|
        expect(described_class.match?(path)).to be(true), path
      end
    end

    it 'does not match a dot inside a name, the allowed dot folders, or names that only contain the words' do
      %w[/ /residents.csv /a.b/c /a/b.env.js /.well-known/x /.vite/manifest.json
         /phpinfo /a.phpx /wp-adminx /my-wp-admin /wp /api/v1/residents/name/wp-adminToken].each do |path|
        expect(described_class.match?(path)).to be(false), path
      end
    end

    it 'counts a dot folder that only starts like an allowed one' do
      expect(described_class.match?('/.well-known-x/a')).to be(true)
      expect(described_class.match?('/.vite2/a')).to be(true)
      expect(described_class.match?('/x/.well-known/a')).to be(true)
      expect(described_class.match?('/.well-known/../.env')).to be(true)
      expect(described_class.match?('/.vite/.git/config')).to be(true)
    end
  end
end
