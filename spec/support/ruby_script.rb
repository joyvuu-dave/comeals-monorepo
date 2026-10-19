# frozen_string_literal: true

require 'open3'

# Runs a Ruby script from bin/ in a process of its own, with its coverage
# measured (spec/bin/preload/simplecov_child.rb) and with any of the other
# files in spec/bin/preload loaded first, such as a fake for an outside
# command. Returns the output (standard and error together) and the status.
#
# bundled: false runs the script outside Bundler, the way bin/bundle runs:
# none of the suite's Bundler settings reach it, so nothing in it can
# resolve the Gemfile or write a lockfile. SimpleCov and the gems it needs
# are then found by their folders (-I) instead.
module RubyScript
  PRELOAD = File.expand_path('../bin/preload', __dir__)

  def run_ruby_script(*command, env: {}, preload: [], chdir: Rails.root.to_s, bundled: true)
    @ruby_script_runs = (@ruby_script_runs || 0) + 1
    files = ['simplecov_child', *preload].map { |name| "-r#{File.join(PRELOAD, name)}" }
    run = lambda do
      base = bundled ? ENV.fetch('RUBYOPT', nil) : simplecov_load_paths.map { |path| "-I#{path}" }.join(' ')
      full = { 'RUBYOPT' => [base, *files].compact.join(' '),
               'SIMPLECOV_CHILD_NAME' => "#{RSpec.current_example.id} #{@ruby_script_runs}" }.merge(env)
      Open3.capture2e(full, *command, chdir: chdir)
    end
    bundled ? run.call : Bundler.with_unbundled_env(&run)
  end

  private

  def simplecov_load_paths(name = 'simplecov', seen = {})
    spec = Gem.loaded_specs[name]
    return [] if seen[name] || spec.nil?

    seen[name] = true
    spec.full_require_paths + spec.runtime_dependencies.flat_map { |dep| simplecov_load_paths(dep.name, seen) }
  end
end

RSpec.configure { |config| config.include RubyScript, file_path: %r{spec/bin/} }
