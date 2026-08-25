# frozen_string_literal: true

require 'rails_helper'

# The scheduled job that keeps the calendar six months ahead. The rotation
# math is covered in spec/tasks/community_create_rotations_spec.rb; this
# pins that the job converges, does nothing when nothing is needed, and
# fails loudly on an unassigned meal.
RSpec.describe EnsureRotationsJob do
  let!(:community) { create(:community) }

  it 'creates rotations until meals exist six months out, and records how many' do
    described_class.perform_now

    expect(community.meals.where(date: (community.today + 6.months)..)).to exist
    run = JobRun.find_by!(name: 'ensure_rotations')
    expect(run.outcome).to eq('ok')
    expect(run.details['rotations_created']).to eq(Rotation.count)
    expect(Rotation.count).to be > 0
  end

  it 'does nothing on a second run' do
    described_class.perform_now

    expect { described_class.perform_now }.not_to change(Rotation, :count)
    expect(JobRun.where(name: 'ensure_rotations').last.details).to eq('rotations_created' => 0)
  end

  it 'fails and records the failure when a meal has no rotation' do
    create(:meal, community: community, rotation: nil)

    expect { described_class.perform_now }.to raise_error(RuntimeError, /not assigned to a rotation/)
    expect(JobRun.find_by!(name: 'ensure_rotations').outcome).to eq('failed')
    expect(Rotation.count).to eq(0)
  end
end
