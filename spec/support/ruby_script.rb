# frozen_string_literal: true

require 'open3'

# Runs a Ruby script from bin/ in a process of its own, with its coverage
# measured (spec/bin/preload/child_coverage.rb) and with any of the other
# files in spec/bin/preload loaded first, such as a fake for an outside
# command. Returns the output (standard and error together) and the status.
module RubyScript
  PRELOAD = File.expand_path('../bin/preload', __dir__)

  def run_ruby_script(*command, env: {}, preload: [], chdir: Rails.root.to_s)
    files = ['child_coverage', *preload].map { |name| "-r#{File.join(PRELOAD, name)}" }
    dir = ENV.fetch('CHILD_COVERAGE_DIR', nil)
    rubyopt = [ENV.fetch('RUBYOPT', nil), *files].compact.join(' ')
    base = { 'RUBYOPT' => rubyopt, 'CHILD_COVERAGE_DIR' => dir }
    Open3.capture2e(base.merge(env), *command, chdir: chdir)
  end
end

RSpec.configure { |config| config.include RubyScript, file_path: %r{spec/bin/} }
