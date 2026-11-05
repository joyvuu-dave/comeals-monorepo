# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# The task is thin: it reads RESIDENT_ID, BEFORE and WRITE and calls
# CommonHouseHistory.relabel (spec/services/common_house_history_spec.rb).
# Without WRITE=yes it only counts.
RSpec.describe 'history:relabel_as_common_house' do
  before(:all) { RakeTasks.ensure_loaded }

  before { create(:common_house_login) }

  after { Rake::Task['history:relabel_as_common_house'].reenable }

  let!(:community) { create(:community) }
  let(:screen_account) { create(:resident, community: community, unit: create(:unit, community: community)) }
  let!(:old) do
    audit = Audited::Audit.create!(auditable: create(:meal, community: community), action: 'update',
                                   user: screen_account, audited_changes: {})
    audit.update_columns(created_at: Time.utc(2021, 1, 1))
    audit
  end

  # Sets only the given variables, and puts all three back afterwards.
  def run_task(env)
    names = %w[RESIDENT_ID BEFORE WRITE]
    saved = names.index_with { |name| ENV.fetch(name, nil) }
    names.each { |name| ENV.delete(name) }
    env.each { |name, value| ENV[name.to_s] = value }
    Rake::Task['history:relabel_as_common_house'].invoke
  ensure
    saved.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  it 'counts and changes nothing without WRITE=yes' do
    expect { run_task(RESIDENT_ID: screen_account.id.to_s, BEFORE: '2021-10-26T00:00:00-07:00') }
      .to output("1 history row would be relabeled as the Common House. Run again with WRITE=yes to change it.\n")
      .to_stdout
    expect(old.reload.user_type).to eq('Resident')
  end

  it 'relabels with WRITE=yes' do
    expect { run_task(RESIDENT_ID: screen_account.id.to_s, BEFORE: '2021-10-26T00:00:00-07:00', WRITE: 'yes') }
      .to output("Relabeled 1 history row as the Common House.\n").to_stdout
    expect(old.reload.user_type).to eq('CommonHouseLogin')
  end

  it 'says rows and them for more than one row' do
    second = Audited::Audit.create!(auditable: old.auditable, action: 'update', user: screen_account,
                                    audited_changes: {})
    second.update_columns(created_at: Time.utc(2021, 1, 2))
    env = { RESIDENT_ID: screen_account.id.to_s, BEFORE: '2021-10-26T00:00:00-07:00' }

    expect { run_task(env) }
      .to output("2 history rows would be relabeled as the Common House. Run again with WRITE=yes to change them.\n")
      .to_stdout
    Rake::Task['history:relabel_as_common_house'].reenable
    expect { run_task(env.merge(WRITE: 'yes')) }.to output("Relabeled 2 history rows as the Common House.\n").to_stdout
  end

  it 'refuses a RESIDENT_ID that is not a number' do
    expect { run_task(RESIDENT_ID: 'sixty', BEFORE: '2021-10-26T00:00:00-07:00', WRITE: 'yes') }
      .to raise_error(ArgumentError, /invalid value for Integer/)
    expect(old.reload.user_type).to eq('Resident')
  end

  it 'refuses when BEFORE is missing' do
    expect { run_task(RESIDENT_ID: screen_account.id.to_s, WRITE: 'yes') }
      .to raise_error(KeyError, /BEFORE/)
  end
end
