# typed: false
# frozen_string_literal: true

if defined?(Rack::MiniProfiler)
  Rack::MiniProfiler.config.storage = Rack::MiniProfiler::MemoryStore
  # The ?pp=profile-memory and ?pp=profile-gc pages. Off by default in the
  # gem; the memory page also needs the memory_profiler gem (Gemfile).
  # Development only: this gem is not in the production bundle.
  Rack::MiniProfiler.config.enable_advanced_debugging_tools = true
end
