# frozen_string_literal: true

require 'rails_helper'

# Part of the fault suite (challenge 30).
RSpec.describe Faults::Driver do
  let(:proxy) { instance_double(Faults::Proxy, cut: 0, down: nil, up: nil) }
  let(:server) { instance_double(Faults::Server, restart: nil) }
  let(:clock) { instance_double(Faults::Clock, move: nil, reset: nil) }

  it 'goes through every kind of fault, and leaves the proxy up and the clock right' do
    driver = described_class.new(proxy: proxy, server: server, clock: clock, seed: 3, every: 0.01)
    allow(driver).to receive(:sleep)
    ticks = (0..).each
    allow(Storm::MONOTONIC).to receive(:call) { ticks.next * 0.01 }

    driver.run(0.07)

    expect(driver.log.map(&:first).first(4)).to match_array(Faults::Driver::KINDS)
    expect(server).to have_received(:restart).at_least(:once)
    expect(proxy).to have_received(:up).at_least(:twice)
    expect(clock).to have_received(:reset).at_least(:twice)
  end

  it 'gives the same order for the same seed' do
    orders = Array.new(2) do
      driver = described_class.new(proxy: proxy, server: server, clock: clock, seed: 3, every: 0.01)
      allow(driver).to receive(:sleep)
      ticks = (0..).each
      allow(Storm::MONOTONIC).to receive(:call) { ticks.next * 0.01 }
      driver.run(0.1).log.map(&:first)
    end
    expect(orders.first).to eq(orders.last)
  end
end
