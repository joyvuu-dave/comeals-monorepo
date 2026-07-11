# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# Pins issue #27: loading rake tasks more than once stacks a duplicate
# action onto every task, so one invoke runs the task body twice. Every
# task spec must go through RakeTasks.ensure_loaded, which loads the
# definitions at most once per process.
#
# No spec may call Rake::Task.clear: recovering means re-loading every
# .rake file, and a re-load resets each file's Ruby coverage counters,
# understating rake task coverage for the whole run. A spec that needs
# the one-action guarantee should assert it, the way
# billing_recalculate_snapshot_spec does.
RSpec.describe 'rake task loading' do
  it 'leaves each task with exactly one action when many spec files ensure loading' do
    # Two calls stand in for two task spec files booting in one process.
    RakeTasks.ensure_loaded
    RakeTasks.ensure_loaded

    expect(Rake::Task['billing:recalculate'].actions.size).to eq(1)
  end
end
