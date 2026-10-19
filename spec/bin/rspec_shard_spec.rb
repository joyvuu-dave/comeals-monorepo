# frozen_string_literal: true

require 'rails_helper'
require 'open3'

# bin/rspec-shard and bin/coverage-collate, which CI uses to run the suite
# in two parts and check the coverage minimum for the whole.
RSpec.describe 'bin/rspec-shard and bin/coverage-collate' do
  def shard(*, env: {}) = Open3.capture2e(env, Rails.root.join('bin/rspec-shard').to_s, *)

  it 'puts every spec file in exactly one part' do
    parts = (1..2).map { shard('--list', it.to_s, '2').first.lines(chomp: true) }

    all = Rails.root.glob('spec/**/*_spec.rb').map { it.relative_path_from(Rails.root).to_s }
    expect(parts.flatten).to match_array(all)
    expect(parts).to all(be_present)
  end

  it 'refuses a part that does not exist, and arguments that are not numbers' do
    [%w[3 2], %w[0 2], %w[x 2], %w[1]].each do |args|
      out, status = shard(*args)

      expect(status.exitstatus).to eq(1)
      expect(out).to include('Usage: bin/rspec-shard')
    end
  end

  it 'writes the seconds per spec file from the JSON reports of the parts' do
    Dir.mktmpdir do |dir|
      report = File.join(dir, 'part.json')
      examples = [{ file_path: './spec/a_spec.rb', run_time: 1.004 },
                  { file_path: './spec/a_spec.rb', run_time: 2.0 },
                  { file_path: './spec/b_spec.rb', run_time: 0.5 }]
      File.write(report, { examples: }.to_json)
      times = File.join(dir, 'times.json')

      out, status = shard('--times', report, env: { 'RSPEC_FILE_TIMES' => times })

      expect(status).to be_success
      expect(out).to include('Wrote 2 files')
      expect(JSON.parse(File.read(times))).to eq('spec/a_spec.rb' => 3.0, 'spec/b_spec.rb' => 0.5)
    end
  end

  it 'refuses to join coverage when a part is missing' do
    Dir.mktmpdir do |dir|
      resultset = File.join(dir, '.resultset.json')
      File.write(resultset, { 'RSpec shard 1' => { 'coverage' => {}, 'timestamp' => 0 } }.to_json)

      out, status = Open3.capture2e(Rails.root.join('bin/coverage-collate').to_s, '2', resultset)

      expect(status.exitstatus).to eq(1)
      expect(out).to include('Expected the results RSpec shard 1, RSpec shard 2; found RSpec shard 1')
    end
  end
end
