# typed: false
# frozen_string_literal: true

# rack-mini-profiler is in the development group of the Gemfile only, so
# other environments have no profiler. A method, so a spec can
# call it with a profiler (spec/config/initializers/rack_mini_profiler_spec.rb).
module MiniProfilerSetup
  def self.configure(profiler)
    return unless profiler

    profiler.config.storage = profiler::MemoryStore
    # The ?pp=profile-memory and ?pp=profile-gc pages. Off by default in the
    # gem; the memory page also needs the memory_profiler gem (Gemfile).
    # Development only: this gem is not in the production bundle.
    profiler.config.enable_advanced_debugging_tools = true
  end
end

MiniProfilerSetup.configure(defined?(Rack::MiniProfiler) && Rack::MiniProfiler)
