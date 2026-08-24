# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Community do
  let(:community) { create(:community) }

  it 'defaults to 19:00 every day' do
    expect(community.dinner_start_times).to eq(Array.new(7, '19:00'))
  end

  describe 'the writer' do
    it 'accepts the admin form hash, keyed by weekday' do
      community.dinner_start_times = { '0' => '18:00', '1' => '19:00', '2' => '19:00', '3' => '19:00',
                                       '4' => '19:00', '5' => '19:00', '6' => '19:00' }

      expect(community.dinner_start_times).to eq(%w[18:00 19:00 19:00 19:00 19:00 19:00 19:00])
    end

    it 'fills a blank field with the default' do
      community.dinner_start_times = { '0' => '18:00', '1' => '', '2' => nil }

      expect(community.dinner_start_times).to eq(%w[18:00 19:00 19:00 19:00 19:00 19:00 19:00])
    end
  end

  describe 'validation' do
    it 'refuses a time that is not HH:MM on a 24-hour clock' do
      community.dinner_start_times = %w[7pm 19:00 19:00 19:00 19:00 19:00 19:00]

      expect(community).not_to be_valid
      expect(community.errors[:dinner_start_times]).to be_present
    end

    it 'refuses the wrong number of days' do
      community.dinner_start_times = %w[19:00 19:00]

      expect(community).not_to be_valid
    end
  end

  describe '#dinner_start_at' do
    before { community.update!(dinner_start_times: %w[18:00 19:00 19:00 19:00 19:00 19:00 19:00]) }

    it "is that weekday's time on that date, in the community's zone" do
      sunday = Date.new(2026, 4, 5)
      tuesday = Date.new(2026, 4, 7)

      expect(community.dinner_start_at(sunday).iso8601).to eq('2026-04-05T18:00:00-07:00')
      expect(community.dinner_start_at(tuesday).iso8601).to eq('2026-04-07T19:00:00-07:00')
    end

    # The 2018 bug: Date#to_datetime + 19.hours is 19:00 UTC, which is noon
    # Pacific. The moment must be built in the zone, for that date, so the
    # offset follows that date's daylight-saving rule.
    it 'follows the daylight-saving rule of the date, not of today' do
      day_before_dst = Date.new(2026, 3, 7)  # Saturday, PST
      dst_sunday = Date.new(2026, 3, 8)      # Sunday, PDT begins at 02:00

      expect(community.dinner_start_at(day_before_dst).utc.iso8601).to eq('2026-03-08T03:00:00Z')
      expect(community.dinner_start_at(dst_sunday).utc.iso8601).to eq('2026-03-09T01:00:00Z')
    end

    it 'uses the community zone, not the app zone' do
      community.update!(timezone: 'America/New_York')

      expect(community.dinner_start_at(Date.new(2026, 4, 7)).iso8601).to eq('2026-04-07T19:00:00-04:00')
    end
  end
end
