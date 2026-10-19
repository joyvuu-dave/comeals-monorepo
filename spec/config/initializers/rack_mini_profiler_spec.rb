# frozen_string_literal: true

require 'rails_helper'

# rack-mini-profiler is in the development group of the Gemfile, so the test
# environment has no Rack::MiniProfiler. A stand-in with the same two names
# takes its place.
RSpec.describe 'config/initializers/rack_mini_profiler.rb' do
  let(:settings) { Struct.new(:storage, :enable_advanced_debugging_tools).new }
  let(:profiler) do
    target = settings
    Module.new do
      const_set(:MemoryStore, Class.new)
      define_singleton_method(:config) { target }
    end
  end

  it 'keeps profiles in memory and turns on the memory and GC pages' do
    MiniProfilerSetup.configure(profiler)

    expect([settings.storage, settings.enable_advanced_debugging_tools]).to eq([profiler::MemoryStore, true])
  end

  it 'does nothing when the gem is not loaded' do
    expect(MiniProfilerSetup.configure(false)).to be_nil
  end
end
