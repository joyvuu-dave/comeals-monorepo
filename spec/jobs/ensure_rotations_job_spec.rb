# frozen_string_literal: true

require 'rails_helper'

# The scheduled job that keeps the calendar six months ahead. The rotation
# math is covered in spec/tasks/community_create_rotations_spec.rb; this
# pins that the job converges and does nothing when nothing is needed.
RSpec.describe EnsureRotationsJob do
  include ActiveSupport::Testing::TimeHelpers

  include_context 'with a stop for a rotation loop that never ends'

  let!(:community) { create(:community) }

  it 'creates rotations until meals exist six months out, and records how many' do
    described_class.perform_now

    expect(community.meals.where(date: (community.today + 6.months)..)).to exist
    run = JobRun.find_by!(name: 'ensure_rotations')
    expect(run.outcome).to eq('ok')
    expect(run.details['rotations_created']).to eq(Rotation.count)
    expect(Rotation.count).to be > 0
  end

  # The admin forms refuse a date after the last meal (#143,
  # spec/requests/admin/meal_date_after_last_rotation_spec.rb). The job
  # makes exactly those dates, so that rule must not apply to it.
  it 'still makes rotations after the last meal' do
    travel_to(Time.zone.local(2026, 1, 15, 12)) { described_class.perform_now }
    last_date = community.meals.maximum(:date)

    travel_to(Time.zone.local(2026, 2, 15, 12)) do
      expect { described_class.perform_now }.to change(Rotation, :count)
    end
    expect(community.meals.where(date: (last_date + 1)..)).to exist
  end

  # The log line says how many rotations a run made. A run that made none
  # writes no line, because that is the normal outcome every night.
  it 'logs how many rotations it made, and logs nothing when it made none' do
    allow(Rails.logger).to receive(:info).and_call_original

    described_class.perform_now
    made = Rotation.count
    described_class.perform_now

    expect(Rails.logger).to have_received(:info).with(/\Aensure_rotations:/).once
    expect(Rails.logger).to have_received(:info).with("ensure_rotations: #{made} rotation(s) created")
  end

  it 'does nothing on a second run' do
    described_class.perform_now

    expect { described_class.perform_now }.not_to change(Rotation, :count)
    expect(JobRun.where(name: 'ensure_rotations').last.details).to eq('rotations_created' => 0)
  end

  # The job counts six months from the community's today, not the app
  # zone's. At 09:00 UTC on 2026-01-16 it is January 16 in the app's zone
  # (Los Angeles) and still January 15 in Honolulu. A meal on July 15 is
  # six months from Honolulu's today, so nothing is needed; counted from
  # the app zone's today it would be a day short.
  it "counts the six months from the community's today" do
    community.update!(timezone: 'Pacific/Honolulu')
    travel_to(Time.utc(2026, 1, 16, 9, 0)) do
      create(:meal, community: community, rotation: create(:rotation, community: community),
                    date: Date.new(2026, 7, 15))
      expect(Time.zone.today).to eq(Date.new(2026, 1, 16))

      expect { described_class.perform_now }.not_to change(Rotation, :count)
    end
  end

  # The last day a dinner may have is December 31, 9999 (CalendarWindow).
  # From July 9999 on, six months ahead is the year 10000, which the
  # window refuses. The job makes dinners up to the last day, and then
  # stops without an error, every night until the end.
  describe 'at the end of 9999' do
    it 'makes dinners up to December 31, 9999 and none after' do
      travel_to(Time.zone.local(9999, 9, 1, 12)) { described_class.perform_now }

      last = community.meals.maximum(:date)
      expect(last).to be <= CalendarWindow::LAST_DAY
      expect(community.meal_schedule.upcoming_dates(from: last + 1, count: 1)).to eq([])
      expect(JobRun.find_by!(name: 'ensure_rotations').outcome).to eq('ok')
    end

    it 'does nothing, and says so, on a run after the last dinner is made' do
      travel_to(Time.zone.local(9999, 9, 1, 12)) { described_class.perform_now }

      travel_to(Time.zone.local(9999, 12, 31, 12)) do
        expect { described_class.perform_now }.not_to change(Rotation, :count)
      end
      expect(JobRun.where(name: 'ensure_rotations').last.outcome).to eq('ok')
    end
  end
end
