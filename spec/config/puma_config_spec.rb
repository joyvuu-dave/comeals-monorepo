# frozen_string_literal: true

require 'rails_helper'
require 'open3'

# Heroku starts the web dyno with `bundle exec puma -C config/puma.rb`
# (Procfile), and Puma reads config/puma.rb before Rails is loaded. So
# the file may use plain Ruby only. On the laptop, bin/dev and bin/prod
# start `rails server`, which loads Rails first, so a Rails method in
# this file works there and crashes every boot on Heroku. That happened
# with `present?`: the staging trial run of 2026-10-06 crashed on boot
# with "undefined method 'present?' for nil".
#
# Each example loads the file the way Heroku does, in its own Ruby
# process that has Puma and nothing from Rails.
RSpec.describe 'config/puma.rb' do
  let(:probe) do
    <<~RUBY
      require 'json'
      require 'puma'
      require 'puma/configuration'
      config = Puma::Configuration.new({}, {}, ENV) { |user| user.load 'config/puma.rb' }
      config.load
      puts JSON.generate(
        rails_loaded: defined?(ActiveSupport) ? true : false,
        plugins: Puma::Plugins.instance_variable_get(:@plugins).keys.sort
      )
    RUBY
  end

  def load_config(solid_queue_in_puma)
    output, status = Open3.capture2e(
      { 'SOLID_QUEUE_IN_PUMA' => solid_queue_in_puma, 'RUBYOPT' => nil },
      'bundle', 'exec', 'ruby', '-e', probe,
      chdir: Rails.root.to_s
    )
    expect(status).to be_success, output
    JSON.parse(output.lines.last)
  end

  it 'loads without Rails when SOLID_QUEUE_IN_PUMA is not set, and runs no Solid Queue' do
    result = load_config(nil)

    expect(result['rails_loaded']).to be(false)
    expect(result['plugins']).to eq(['tmp_restart'])
  end

  it 'treats an empty SOLID_QUEUE_IN_PUMA as not set' do
    expect(load_config('')['plugins']).to eq(['tmp_restart'])
    expect(load_config(' ')['plugins']).to eq(['tmp_restart'])
  end

  it 'loads without Rails when SOLID_QUEUE_IN_PUMA is set, and starts the Solid Queue plugin' do
    result = load_config('true')

    expect(result['rails_loaded']).to be(false)
    expect(result['plugins']).to eq(%w[solid_queue tmp_restart])
  end
end
