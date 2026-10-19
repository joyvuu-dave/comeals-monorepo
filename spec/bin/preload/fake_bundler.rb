# frozen_string_literal: true

# For the bin/bundle examples in spec/bin/binstubs_spec.rb, which run it
# outside Bundler.
#
# - Gem.bin_path names bundle_command.rb here instead of Bundler's own
#   command, which prints what it was run with, so `bin/bundle update`
#   updates nothing and nothing writes a lockfile.
# - FAKE_RUBYGEMS_VERSION stands in for the version of RubyGems, for the
#   branch the binstub keeps for RubyGems older than 2.7.
# - FAKE_BUNDLER_GEM_ERROR makes the first `gem "bundler"` raise, as it
#   can where the right Bundler is loaded anyway.
module FakeBundlerCommand
  def bin_path(name, *)
    name == 'bundler' ? File.expand_path('bundle_command.rb', __dir__) : super
  end

  def rubygems_version
    ENV.key?('FAKE_RUBYGEMS_VERSION') ? Gem::Version.new(ENV.fetch('FAKE_RUBYGEMS_VERSION')) : super
  end
end
Gem.singleton_class.prepend(FakeBundlerCommand)

if ENV.key?('FAKE_BUNDLER_GEM_ERROR')
  class Object
    private

    def gem(name, *)
      if name == 'bundler' && !$fake_bundler_gem_error_raised # rubocop:disable Style/GlobalVars
        $fake_bundler_gem_error_raised = true # rubocop:disable Style/GlobalVars
        raise Gem::LoadError, "can't activate #{name}"
      end

      super
    end
  end
end
