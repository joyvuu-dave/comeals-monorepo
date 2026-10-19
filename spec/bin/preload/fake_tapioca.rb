# frozen_string_literal: true

# For spec/bin/tapioca_spec.rb. bin/tapioca ends by loading the tapioca
# gem's command; this makes RubyGems name tapioca_command.rb here instead,
# which prints what it was run with.
module FakeTapiocaCommand
  def bin_path(name, *)
    name == 'tapioca' ? File.expand_path('tapioca_command.rb', __dir__) : super
  end
end
Gem.singleton_class.prepend(FakeTapiocaCommand)
