# frozen_string_literal: true

require 'rails_helper'

# Heroku runs one dyno per process type in the Procfile. The web dyno runs
# Puma only. The jobs run on a dyno of their own, the worker, which runs
# bin/jobs: Solid Queue's supervisor, in fork mode, with config/queue.yml
# (spec/config/initializers/solid_queue_spec.rb). The release phase checks
# the config vars and then migrates (lib/deploy_config_check.rb).
RSpec.describe 'Procfile' do
  let(:processes) do
    Rails.root.join('Procfile').readlines(chomp: true).reject(&:empty?)
         .to_h { |line| line.split(/:\s*/, 2) }
  end

  it 'has a web, a worker and a release process, and nothing else' do
    expect(processes).to eq(
      'web' => 'bundle exec puma -C config/puma.rb',
      'worker' => 'bin/jobs',
      'release' => 'bin/rake deploy:verify_config db:migrate'
    )
  end
end
