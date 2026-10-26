# frozen_string_literal: true

require 'rails_helper'

# Every GitHub Actions job runs on ubuntu-26.04: the Ubuntu of Heroku's
# heroku-26 stack, which production runs. Not ubuntu-latest, which GitHub
# moves to a new Ubuntu on its own date (the note at the top of
# .github/workflows/ci.yml's jobs).
RSpec.describe '.github/workflows' do
  let(:jobs) do
    Rails.root.glob('.github/workflows/*.yml').sort.flat_map do |file|
      YAML.safe_load_file(file.to_s)['jobs'].map { |name, job| ["#{file.basename}: #{name}", job] }
    end
  end

  it 'runs every job on ubuntu-26.04' do
    expect(jobs).not_to be_empty
    expect(jobs.reject { |_name, job| job['runs-on'] == 'ubuntu-26.04' }.map(&:first)).to eq([])
  end
end
