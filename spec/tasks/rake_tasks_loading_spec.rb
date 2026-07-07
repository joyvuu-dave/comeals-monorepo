# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# Pins issue #27: loading rake tasks more than once stacks a duplicate
# action onto every task, so one invoke runs the task body twice. Every
# task spec must go through RakeTasks.ensure_loaded, which loads the
# definitions at most once per process.
RSpec.describe 'rake task loading' do
  it 'leaves each task with exactly one action when many spec files ensure loading' do
    # Two calls stand in for two task spec files booting in one process.
    RakeTasks.ensure_loaded
    RakeTasks.ensure_loaded

    expect(Rake::Task['billing:recalculate'].actions.size).to eq(1)
  end

  it 'reloads after something wipes rake state' do
    # The billing snapshot spec calls Rake::Task.clear. Task spec files that
    # run after it still need the tasks back — with one action each.
    RakeTasks.ensure_loaded
    Rake::Task.clear
    RakeTasks.ensure_loaded

    expect(Rake::Task.task_defined?('billing:recalculate')).to be(true)
    expect(Rake::Task['billing:recalculate'].actions.size).to eq(1)
  end
end
