# frozen_string_literal: true

require 'rails_helper'
require 'open3'

# A short real run of bin/faults (challenge 30): its own PostgreSQL, a
# Puma, and the proxy, with every kind of fault at least once and a third
# of the answers to writes lost and sent again. The books must be right
# after, no write saved twice, no write answered with an error after it
# was saved, and no 500 while the database is gone.
RSpec.describe 'bin/faults' do
  it 'keeps the books right and answers every request well while things break' do
    env = { 'FAULTS_SECONDS' => '12', 'FAULTS_CLIENTS' => '6', 'FAULTS_EVERY' => '1', 'FAULTS_LOSE' => '0.3',
            'FAULTS_SEED' => '2' }
    output, status = Open3.capture2e(env, Rails.root.join('bin/faults').to_s, chdir: Rails.root.to_s)

    faults = output[/^faults: (.*)$/, 1].to_s
    expect(Faults::Driver::KINDS.map(&:to_s)).to all(satisfy { faults.include?(it) }), output
    expect(output).to include('No problems.'), output.lines.grep_v(%r{\A\s+/}).last(60).join
    expect(status).to be_success
  end
end
