# frozen_string_literal: true

require 'rails_helper'

# Inside a simulation, the clock, sleep and randomness come from the
# seed, so a replay sees the same times and the same random values.
RSpec.describe Simulation::Determinism do
  include_context 'with no test transaction'
  include_context 'with a pool for a simulation', 8
  include ActiveSupport::Testing::TimeHelpers

  let(:start) { Time.utc(2026, 11, 4, 1, 30) }
  let(:ruby_defaults) do
    [[:sleep, Kernel, false], [:rand, Kernel, false], [:rand, Kernel.singleton_class, false],
     [:rand, Random.singleton_class, false], [:random_bytes, Random::Formatter, false],
     [:random_number, Random::Formatter, false], [:gen_random, SecureRandom.singleton_class, false],
     [:now, Time.singleton_class, false]]
  end

  def run(seed)
    scheduler = Simulation::Scheduler.new(seed: seed, start: start)
    %i[a b].each do |name|
      scheduler.actor(name) do
        before = Time.current
        ActiveRecord::Base.connection.execute('SELECT 1')
        sleep(5)
        { before: before, after: Time.current, uuid: SecureRandom.uuid, hex: SecureRandom.hex(4),
          rand: Kernel.rand, ruby_rand: rand(1000) }
      end
    end
    scheduler.run.values
  end

  it 'gives the same times and random values for the same seed' do
    first, second = Array.new(2) { run(4) }
    expect(first).to eq(second)
  end

  it 'gives different random values for different seeds' do
    expect(run(4).transform_values { |v| v[:uuid] }).not_to eq(run(5).transform_values { |v| v[:uuid] })
  end

  it 'starts the clock at the given time and moves it by what sleep asks, without waiting' do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    values = run(4)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
    values.each_value do |v|
      expect(v[:before]).to be_between(start, start + 1)
      expect(v[:after] - v[:before]).to be_between(5, 6)
    end
  end

  it 'puts the real clock, sleep and randomness back after the run' do
    run(4)
    real = Time.at(Process.clock_gettime(Process::CLOCK_REALTIME)).utc
    expect(Time.now.utc).to be_within(60).of(real)
    expect(SecureRandom.uuid).not_to eq(SecureRandom.uuid)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    sleep(0.05)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be >= 0.05
  end

  # Each method, the class or module it is on, and whether this app's
  # code defines it. Ruby's own are on the class or module Ruby puts them
  # on, and are written in C or in Ruby's own files.
  def ruby_owned
    [Object.instance_method(:sleep), Object.instance_method(:rand), Kernel.method(:rand),
     Random.method(:rand), SecureRandom.method(:random_bytes), SecureRandom.method(:random_number),
     SecureRandom.method(:gen_random), Time.method(:now)]
      .map { [it.name, it.owner, it.source_location&.first.to_s.start_with?(Rails.root.to_s)] }
  end

  # A hook that stayed in place for the whole test run could break a
  # library that stubs one of these methods by renaming it, the way
  # travel_to broke (below). So every hook is there only while a
  # simulation runs, and Ruby's own method is back after.
  it "leaves Ruby's own sleep, rand, SecureRandom and Time.now in place outside a simulation" do
    expect(ruby_owned).to eq(ruby_defaults)
    during = nil
    scheduler = Simulation::Scheduler.new(seed: 4, start: start)
    scheduler.actor(:a) { during = ruby_owned }
    scheduler.run
    expect(during.map(&:last)).to all(be(true))
    expect(ruby_owned).to eq(ruby_defaults)
  end

  # A thread an actor starts is not an actor, so it gets Ruby's own
  # methods, with the same arguments.
  it "passes a call from a thread that is not an actor to Ruby's own method" do
    scheduler = Simulation::Scheduler.new(seed: 4, start: start)
    scheduler.actor(:a) do
      Thread.new do
        [rand(1..6), Kernel.rand(1..6), Random.rand(1.0..2.0), SecureRandom.random_number(1..6), sleep(0)]
      end.value
    end
    first, second, third, fourth, slept = scheduler.run.values.fetch(:a)
    expect([first, second, fourth]).to all(be_between(1, 6))
    expect(third).to be_between(1.0, 2.0)
    expect(slept).to eq(0)
  end

  it 'keeps sleep and rand private on every object' do
    expect(Object.private_method_defined?(:sleep)).to be(true)
    expect(Object.private_method_defined?(:rand)).to be(true)
  end

  # Rails' travel_to stubs Time.now by renaming it and puts it back the
  # same way. A module prepended to Time for good made the put-back
  # Time.now call itself forever, in every spec that used travel_to.
  it 'leaves travel_to working, before and after a simulation' do
    travel_to(start) { expect(Time.now.utc).to eq(start) }
    expect(Time.now.utc).to be_within(60).of(Process.clock_gettime(Process::CLOCK_REALTIME).then { Time.at(it).utc })

    run(4)
    travel_to(start + 10) { expect(Time.now.utc).to eq(start + 10) }
    expect(Time.now.utc).to be_within(60).of(Process.clock_gettime(Process::CLOCK_REALTIME).then { Time.at(it).utc })
  end

  it 'reads a travel_to time outside the simulation, and its own clock inside it' do
    travel_to(start + 3600) do
      expect(run(4).values.pluck(:before)).to all(be < start + 60)
      expect(Time.now.utc).to eq(start + 3600)
    end
  end
end
