# frozen_string_literal: true

require 'rails_helper'

# config/initializers/pusher.rb runs once at boot, in the test environment.
# These examples call its methods the way the other environments do.
RSpec.describe 'config/initializers/pusher.rb' do
  let(:pusher) { Struct.new(:app_id, :key, :secret, :cluster, :logger, :encrypted).new }
  let(:logger) { Logger.new(nil) }
  let(:vars) do
    { 'PUSHER_APP_ID' => '1001', 'PUSHER_KEY' => 'k', 'PUSHER_SECRET' => 's', 'PUSHER_CLUSTER' => 'us3' }
  end

  def env(name)
    ActiveSupport::EnvironmentInquirer.new(name)
  end

  describe '.configure' do
    it 'reads every setting from the environment variables in production' do
      PusherSetup.configure(pusher, env: env('production'), vars: vars, logger: logger)

      expect(pusher.to_h).to eq(app_id: '1001', key: 'k', secret: 's', cluster: 'us3',
                                logger: logger, encrypted: true)
    end

    it 'refuses to boot production when a setting is missing' do
      expect do
        PusherSetup.configure(pusher, env: env('production'), vars: vars.except('PUSHER_SECRET'), logger: logger)
      end.to raise_error(KeyError, /PUSHER_SECRET/)
    end

    it 'uses placeholders in the test environment when nothing is set' do
      PusherSetup.configure(pusher, env: env('test'), vars: {}, logger: logger)

      expect(pusher.to_h.values_at(:app_id, :key, :secret, :cluster)).to eq(%w[test test test test])
    end

    it 'still uses the variables in the test environment when they are set' do
      PusherSetup.configure(pusher, env: env('test'), vars: vars, logger: logger)

      expect(pusher.app_id).to eq('1001')
    end

    it 'is what ran at boot' do
      expect(Pusher.app_id).to eq(ENV.fetch('PUSHER_APP_ID', 'test'))
    end
  end

  describe '.silence_outside_production' do
    let(:pusher) { Object.new }

    it 'makes trigger send nothing on the integration test server' do
      PusherSetup.silence_outside_production(pusher, vars: { 'INTEGRATION_SERVER' => '1' })

      expect(pusher.trigger('meal-1', 'update', {})).to be(true)
    end

    it 'makes trigger send nothing on the staging app' do
      PusherSetup.silence_outside_production(pusher, vars: { 'COMEALS_STAGING' => '1' })

      expect(pusher.trigger('meal-1', 'update', {})).to be(true)
    end

    it 'leaves trigger alone everywhere else' do
      PusherSetup.silence_outside_production(pusher, vars: { 'INTEGRATION_SERVER' => '' })

      expect(pusher).not_to respond_to(:trigger)
    end
  end
end
