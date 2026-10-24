# frozen_string_literal: true

require 'rails_helper'

# Sprockets only joins the admin script's files unless a compressor is
# set, so production served active_admin.js as 659,585 bytes (172,041
# gzipped) of plain source. Every admin page loads it, and on a slow
# phone its download held back the page's first paint. Terser cuts it to
# about 271,000 bytes (79,000 gzipped).
RSpec.describe 'The admin script' do
  # The test environment uses the same compressor, so the admin browser
  # suites (tests/admin) run the script production serves.
  it 'is minified with terser in production and in the browser tests' do
    %w[production test].each do |env|
      config = Rails.root.join("config/environments/#{env}.rb").read

      expect(config).to match(/^\s*config\.assets\.js_compressor = :terser$/), env
    end
  end

  # The compressor runs at deploy time (rake assets:precompile), so a
  # script it cannot read would fail the deploy, not a test. This builds
  # the real admin script with it.
  it 'comes out at less than half the size of its plain source' do
    expect(Rails.application.config.assets.js_compressor).to eq(:terser)

    built = Rails.application.assets['active_admin.js'].to_s

    expect(built.bytesize).to be < 659_585 / 2
  end
end
