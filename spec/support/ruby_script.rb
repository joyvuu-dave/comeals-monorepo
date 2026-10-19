# frozen_string_literal: true

require 'open3'

# Runs a Ruby script from bin/ in a process of its own, with its coverage
# measured (spec/bin/preload/simplecov_child.rb) and with any of the other
# files in spec/bin/preload loaded first, such as a fake for an outside
# command. Returns the output (standard and error together) and the status.
module RubyScript
  PRELOAD = File.expand_path('../bin/preload', __dir__)

  def run_ruby_script(*command, env: {}, preload: [], chdir: Rails.root.to_s)
    @ruby_script_runs = (@ruby_script_runs || 0) + 1
    files = ['simplecov_child', *preload].map { |name| "-r#{File.join(PRELOAD, name)}" }
    env = { 'RUBYOPT' => [ENV.fetch('RUBYOPT', nil), *files].compact.join(' '),
            'SIMPLECOV_CHILD_NAME' => "#{RSpec.current_example.id} #{@ruby_script_runs}" }.merge(env)
    Open3.capture2e(env, *command, chdir: chdir)
  end
end

RSpec.configure { |config| config.include RubyScript, file_path: %r{spec/bin/} }
