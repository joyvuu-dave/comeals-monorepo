# frozen_string_literal: true

require 'rails_helper'
require 'open3'

# Heroku runs one dyno per process type in the Procfile. The web dyno runs
# Puma only. The jobs run on a dyno of their own, the worker, which runs
# bin/jobs: Solid Queue's supervisor, in fork mode, with config/queue.yml
# (spec/config/initializers/solid_queue_spec.rb). The release phase
# migrates.
RSpec.describe 'Procfile' do
  let(:processes) do
    Rails.root.join('Procfile').readlines(chomp: true).reject(&:empty?)
         .to_h { |line| line.split(/:\s*/, 2) }
  end

  # The pool the worker line gives its processes, from `env RAILS_DB_POOL=N`.
  let(:worker_pool) { Integer(processes.fetch('worker')[/\Aenv RAILS_DB_POOL=(\d+) /, 1], 10) }

  it 'has a web, a worker and a release process, and nothing else' do
    expect(processes).to eq(
      'web' => 'bundle exec puma -C config/puma.rb',
      'worker' => 'env RAILS_DB_POOL=3 bin/jobs',
      'release' => 'bin/rake db:migrate'
    )
  end

  # Web, one-off dynos and the release phase keep config/database.yml's
  # default pool of 2 (the request thread and solid_cache's trim thread).
  # Each Solid Queue process needs more: Solid Queue's own estimate for
  # config/queue.yml is a connection per worker thread, plus one for the
  # polling thread and one for the heartbeat. So `threads: 3` in
  # config/queue.yml without a larger pool here fails this example
  # instead of starting with too few connections.
  it 'gives the jobs processes at least the pool Solid Queue estimates for config/queue.yml' do
    estimate = SolidQueue::Configuration.new(mode: :fork).send(:estimated_database_pool_size)

    expect(worker_pool).to be >= estimate
  end

  # Heroku's own Procfile example sets a variable with `env QUEUE=*
  # bundle exec rake resque:work`, and env works whether or not a shell
  # reads the line. This runs the worker line the same way, with a probe
  # in place of bin/jobs, and asks the booted app for its pool.
  it 'starts the jobs process with that pool' do
    command = processes.fetch('worker').delete_suffix(' bin/jobs').split +
              ['bin/rails', 'runner', 'print ActiveRecord::Base.connection_db_config.max_connections']
    output, status = Open3.capture2e({ 'RAILS_ENV' => 'test', 'RUBYOPT' => nil, 'RAILS_DB_POOL' => '9' },
                                     *command, chdir: Rails.root.to_s)

    expect(status).to be_success, output
    expect(output.lines.last).to eq(worker_pool.to_s)
  end
end
