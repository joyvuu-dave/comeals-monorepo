# frozen_string_literal: true

require 'rails_helper'
require 'open3'

# SnapshotRead opens the nightly balance refresh and the ledger check as
# SERIALIZABLE READ ONLY DEFERRABLE when config.x.snapshot_reads_deferrable
# is on. DEFERRABLE is what makes those reads unable to fail with a
# serialization error. config/application.rb turns it on, and only the
# test environment turns it off (config/environments/test.rb). This
# process runs in the test environment, so it cannot see the other
# values. Each example reads them the way that environment boots:
# config/application.rb first, then the environment's own file, in a
# separate Ruby process. Nothing is initialized and nothing connects to a
# database.
RSpec.describe 'config.x.snapshot_reads_deferrable' do
  def setting_in(env)
    probe = <<~RUBY
      require './config/application'
      load 'config/environments/#{env}.rb'
      puts Rails.application.config.x.snapshot_reads_deferrable.inspect
    RUBY
    output, status = Open3.capture2e(
      { 'RAILS_ENV' => env, 'RUBYOPT' => nil },
      'bundle', 'exec', 'ruby', '-e', probe,
      chdir: Rails.root.to_s
    )
    expect(status).to be_success, output
    output.lines.last.chomp
  end

  %w[production development].each do |env|
    it "is on in the #{env} environment" do
      expect(setting_in(env)).to eq('true')
    end
  end

  it 'is off in the test environment' do
    expect(Rails.application.config.x.snapshot_reads_deferrable).to be(false)
  end
end
