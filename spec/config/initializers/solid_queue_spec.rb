# frozen_string_literal: true

require 'rails_helper'

# The jobs run on their own dyno (`worker: bin/jobs` in the Procfile).
# bin/jobs starts Solid Queue's supervisor in fork mode, and the supervisor
# forks a dispatcher, a worker and a scheduler (config/queue.yml,
# config/recurring.yml). The boot catch-up (RecurringCatchUp) must run once
# each time that dyno starts, not once in each of the three forks, so
# config/initializers/solid_queue.rb hangs it on the supervisor's start
# hook.
RSpec.describe 'config/initializers/solid_queue.rb' do
  it 'adds one start hook to the supervisor and none to the processes it forks' do
    expect(SolidQueue::Supervisor.lifecycle_hooks[:start].size).to eq(1)
    [SolidQueue::Dispatcher, SolidQueue::Worker, SolidQueue::Scheduler].each do |process|
      expect(process.lifecycle_hooks[:start]).to eq([]), process.name
    end
  end

  # The supervisor is the real one bin/jobs builds, from config/queue.yml.
  # Only the parts that touch the outside are stubbed: booting (it writes
  # its process row), forking each process, and the loop that watches the
  # forks.
  it 'runs the catch-up once when the supervisor starts, before it forks its three processes' do
    events = []
    allow(RecurringCatchUp).to receive(:call) { events << :catch_up }
    supervisor = SolidQueue::ForkSupervisor.new(SolidQueue::Configuration.new(mode: :fork))
    allow(supervisor).to receive(:boot)
    allow(supervisor).to receive(:start_process) { |process| events << process.kind }
    allow(supervisor).to receive(:launch_maintenance_task)
    allow(supervisor).to receive(:supervise)

    supervisor.start

    expect(events).to eq(%i[catch_up dispatcher worker scheduler])
  end
end
