# frozen_string_literal: true

require 'rails_helper'

# A request for a path that no route matches is answered 404. Scanners
# send many of these at once (117 in two seconds on 2026-10-23, all for
# files like /.env and /.git/config). Rails logged each one at ERROR,
# with a backtrace, so a rule that alerts on ERROR fired for every
# scanner. These check that an unknown path is one INFO line with the
# path, and that a real error is still ERROR with its backtrace. (Those
# secret-file paths are now refused before the router by Rack::Attack,
# rack_attack_probe_spec.rb, so these use paths that are not in its rule.)
RSpec.describe 'The log line for a path no route matches' do
  let(:log) { StringIO.new }
  # The formatter production uses (config/environments/production.rb),
  # which starts each line with the level's letter: "E, [" for ERROR.
  let(:capture) { ActiveSupport::Logger.new(log, formatter: Logger::Formatter.new, level: :debug) }

  # The test environment raises an exception instead of answering it
  # (show_exceptions = :none), and Rails writes the error line only when
  # it answers. So these examples answer the way production does: the
  # plain error page, no details.
  around do |example|
    env_config = Rails.application.env_config
    saved = env_config.slice('action_dispatch.show_exceptions', 'action_dispatch.show_detailed_exceptions')
    env_config['action_dispatch.show_exceptions'] = :all
    env_config['action_dispatch.show_detailed_exceptions'] = false
    Rails.logger.broadcast_to(capture)
    example.run
  ensure
    Rails.logger.stop_broadcasting_to(capture)
    env_config.merge!(saved)
  end

  # The log entries at one level. An entry starts with the level's letter
  # and runs to the next entry, so an error's backtrace lines stay in it.
  def lines(severity)
    log.string.split(/^(?=[DIWEFA], \[)/).select { |entry| entry.start_with?("#{severity[0]}, [") }
  end

  it 'writes one INFO line with the path, and no ERROR line or backtrace, for a path on the admin host' do
    host! 'admin.example.com'
    get '/no-such-page'

    expect(response).to have_http_status(:not_found)
    expect(lines('ERROR')).to be_empty
    expect(lines('FATAL')).to be_empty
    expect(lines('INFO').grep(/No route matches/)).to contain_exactly(a_string_including('[GET] "/no-such-page"'))
    expect(log.string).not_to include('asset_cache_control.rb')
  end

  it 'does the same for an unknown path under /api/' do
    post '/api/v1/no-such-endpoint'

    expect(response).to have_http_status(:not_found)
    expect(lines('ERROR')).to be_empty
    expect(lines('INFO').grep(/No route matches/))
      .to contain_exactly(a_string_including('[POST] "/api/v1/no-such-endpoint"'))
  end

  it 'still writes a real error at ERROR, with its backtrace' do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with('HEROKU_SLUG_COMMIT', nil).and_raise(RuntimeError, 'boom')

    get '/api/v1/version'

    expect(response).to have_http_status(:internal_server_error)
    expect(lines('ERROR')).to contain_exactly(
      a_string_including('RuntimeError (boom)').and(including('app/controllers/api/v1/site_controller.rb'))
    )
  end

  it 'still writes a 404 the app raises for another reason at the level Rails uses' do
    host! 'admin.example.com'
    sign_in create(:admin_user, community: create(:community), superuser: true)
    get '/residents/0'

    expect(response).to have_http_status(:not_found)
    expect(lines('ERROR')).to contain_exactly(a_string_including('ActiveRecord::RecordNotFound'))
  end

  it 'does not send an unknown path to Bugsnag' do
    allow(Bugsnag).to receive(:notify)
    host! 'admin.example.com'
    get '/no-such-page'

    expect(Bugsnag).not_to have_received(:notify)
  end
end
