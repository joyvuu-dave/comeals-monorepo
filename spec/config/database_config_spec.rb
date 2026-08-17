# frozen_string_literal: true

require 'rails_helper'

# Pins the `variables:` blocks in config/database.yml.
#
# Two hazards make these worth a spec. First, YAML merge keys are shallow:
# an environment block that declares its own `variables:` hash replaces the
# default hash entirely, so adding one key there can silently drop
# `default_transaction_isolation` — the single most important line in the
# file (ADR 0005). Second, the settings are issued as SET SESSION on each
# new connection, so a typo fails quietly at connection time, not at boot.
# config/initializers/verify_transaction_isolation.rb catches the isolation
# regression at boot in every environment; this spec catches all of them at
# test time, per environment, including production's block which no test
# process ever connects with.
RSpec.describe 'database configuration' do
  def variables_for(env)
    config = ActiveRecord::Base.configurations.configs_for(env_name: env).first
    config.configuration_hash.fetch(:variables)
  end

  %w[development test production].each do |env|
    describe "the #{env} environment" do
      it 'runs sessions at SERIALIZABLE' do
        expect(variables_for(env)['default_transaction_isolation']).to eq('serializable')
      end

      it 'bounds every statement at 10 seconds' do
        expect(variables_for(env)['statement_timeout']).to eq('10s')
      end

      it 'bounds every lock wait at 5 seconds' do
        expect(variables_for(env)['lock_timeout']).to eq('5s')
      end
    end
  end

  describe 'the production environment' do
    it 'kills a session idling inside an open transaction after 5 minutes' do
      expect(variables_for('production')['idle_in_transaction_session_timeout']).to eq('5min')
    end
  end

  describe 'the live test session' do
    # The block above pins the file; this pins that the file reached
    # PostgreSQL. SHOW reflects the SET SESSION issued at connection time.
    it 'actually runs at SERIALIZABLE with the timeouts set' do
      connection = ActiveRecord::Base.connection
      expect(connection.select_value('SHOW default_transaction_isolation')).to eq('serializable')
      expect(connection.select_value('SHOW statement_timeout')).to eq('10s')
      expect(connection.select_value('SHOW lock_timeout')).to eq('5s')
    end
  end
end
