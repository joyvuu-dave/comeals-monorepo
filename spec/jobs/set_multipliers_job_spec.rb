# frozen_string_literal: true

require 'rails_helper'

# The rule itself, band by band, is in spec/tasks/residents_set_multiplier_spec.rb.
# This pins the bookkeeping of one run.
# Under prosopite: the job preloads each resident's community, and a
# run without the preload is one query per resident from one line.
RSpec.describe SetMultipliersJob, :prosopite do
  let(:community) { create(:community, free_below_age: 5, full_price_age: 12) }
  let(:unit) { create(:unit, community: community) }

  before { allow(Healthcheck).to receive(:ping) }

  it 'counts only the residents it moved, and keeps going past the ones already right' do
    create(:resident, community: community, unit: unit, birthday: 30.years.ago.to_date, multiplier: 2)
    child = create(:resident, community: community, unit: unit, birthday: 8.years.ago.to_date, multiplier: 2)
    create(:resident, community: community, unit: unit, birthday: nil, multiplier: 2)

    described_class.perform_now

    expect(child.reload.multiplier).to eq(1)
    expect(JobRun.last.details).to eq('residents_moved' => 1)
  end

  it 'reports zero moved when everyone is already in the right band' do
    create(:resident, community: community, unit: unit, birthday: 30.years.ago.to_date, multiplier: 2)

    described_class.perform_now

    expect(JobRun.last.details).to eq('residents_moved' => 0)
  end

  # The push. The write is update_columns, so no callback pushes; the job
  # does, once per run, and not at all when nobody moved (every open
  # screen would drop its months and refetch for nothing, every night).
  describe 'the residents push' do
    def residents_channel
      "community-#{community.id}-residents"
    end

    # The residents created above pushed on their own saves; only the run
    # under test counts.
    def forget_pushes_so_far
      RSpec::Mocks.space.proxy_for(Pusher).reset
      allow(Pusher).to receive(:trigger)
    end

    it 'pushes the residents channel once when several residents move' do
      3.times do |n|
        create(:resident, community: community, unit: unit, name: "Child #{n}",
                          birthday: 8.years.ago.to_date, multiplier: 2)
      end
      create(:resident, community: community, unit: unit, name: 'Grown', birthday: 30.years.ago.to_date,
                        multiplier: 1)
      forget_pushes_so_far

      described_class.perform_now

      expect(JobRun.last.details).to eq('residents_moved' => 4)
      expect(Pusher).to have_received(:trigger).with(residents_channel, 'update', anything, any_args).once
    end

    it 'pushes nothing when nobody moved' do
      create(:resident, community: community, unit: unit, birthday: 30.years.ago.to_date, multiplier: 2)
      create(:resident, community: community, unit: unit, birthday: nil, multiplier: 2)
      forget_pushes_so_far

      described_class.perform_now

      expect(Pusher).not_to have_received(:trigger)
    end
  end
end
