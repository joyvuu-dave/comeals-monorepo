# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'config/initializers/integration_fake_time.rb' do
  def env(name)
    ActiveSupport::EnvironmentInquirer.new(name)
  end

  it 'freezes the clock at noon of the given day in the test environment' do
    clock = IntegrationFakeTime.freeze_clock(env: env('test'), today: '2026-01-15')

    expect(Time.current).to eq(Time.zone.parse('2026-01-15 12:00:00'))
  ensure
    clock&.travel_back
  end

  it 'freezes nothing outside the test environment' do
    expect(IntegrationFakeTime.freeze_clock(env: env('development'), today: '2026-01-15')).to be_nil
    expect(Time.current.to_date).not_to eq(Date.new(2026, 1, 15))
  end

  it 'freezes nothing when no day is set' do
    expect(IntegrationFakeTime.freeze_clock(env: env('test'), today: '')).to be_nil
  end
end
