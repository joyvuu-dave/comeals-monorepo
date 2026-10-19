# frozen_string_literal: true

# For a script that reads the repository's .env itself (bin/tapioca): it
# reads FAKE_DOTENV instead, or finds no .env when that is empty. The real
# .env of the checkout differs between a worktree, the main checkout and CI.
module FakeDotenv
  REAL = File.expand_path('../../../.env', __dir__)

  def exist?(path)
    File.expand_path(path) == REAL ? !ENV.fetch('FAKE_DOTENV').empty? : super
  end

  def read(path, *, **)
    File.expand_path(path) == REAL ? super(ENV.fetch('FAKE_DOTENV'), *, **) : super
  end
end
File.singleton_class.prepend(FakeDotenv)
