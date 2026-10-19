# frozen_string_literal: true

require 'rails_helper'

# config/initializers/bugsnag.rb runs once at boot, with no API key. These
# examples call it the way production does, with a configuration object of
# their own, so the gem's real configuration is not changed.
RSpec.describe 'config/initializers/bugsnag.rb' do
  let(:config) { Bugsnag::Configuration.new }
  let(:bugsnag) do
    target = config
    Module.new { define_singleton_method(:configure) { |&block| block.call(target) } }
  end
  let(:errors) { instance_double(ActiveSupport::ErrorReporter, subscribe: nil) }

  def configure(api_key:, env:, release: 'v700')
    BugsnagSetup.configure(bugsnag, errors: errors, api_key: api_key, env: ActiveSupport::EnvironmentInquirer.new(env),
                                    release: release)
  end

  context 'with an API key, in production' do
    before { configure(api_key: 'abc123', env: 'production') }

    it 'sends errors from production only, under the Heroku release' do
      expect([config.api_key, config.release_stage, config.enabled_release_stages, config.app_version])
        .to eq(['abc123', 'production', ['production'], 'v700'])
    end

    it 'drops the errors the app already answers with a 400 or a 406' do
      expect(config.discard_classes).to include('ActionController::BadRequest', 'ActionController::UnknownFormat',
                                                'Rack::QueryParser::InvalidParameterError')
    end

    it 'filters what Rails keeps out of its logs' do
      expect(config.meta_data_filters).to include('password', 'token')
    end

    it 'reports the errors handled through Rails.error' do
      expect(errors).to have_received(:subscribe).with(an_instance_of(BugsnagErrorSubscriber))
    end
  end

  it 'leaves the release out outside production' do
    configure(api_key: 'abc123', env: 'development')

    expect([config.release_stage, config.app_version]).to eq(['development', nil])
  end

  context 'with no API key' do
    before { configure(api_key: nil, env: 'production') }

    it 'turns off session tracking and subscribes nothing' do
      expect([config.api_key, config.auto_capture_sessions]).to eq([nil, false])
      expect(errors).not_to have_received(:subscribe)
    end
  end
end
