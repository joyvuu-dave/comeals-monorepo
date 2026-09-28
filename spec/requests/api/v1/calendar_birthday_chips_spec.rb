# frozen_string_literal: true

require 'rails_helper'

# A birthday chip on the calendar goes on the birthday in the year of the
# weeks on screen, not in this year. The month grid is 42 days, so the
# December grid ends in the next January, and a person can page to any
# month of another year. The chip also says the age the person turns on
# that day, not their age today.
RSpec.describe 'birthday chips on the calendar' do
  include ActiveSupport::Testing::TimeHelpers

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  # A fixed name, so a random first name cannot clash with the ones the chips shorten.
  let(:resident) { create(:resident, community: community, unit: unit, name: 'Ann Lee') }
  let(:token) { resident.keys.first.token }

  def birthday_chips(date)
    get "/api/v1/communities/#{community.id}/calendar/#{date}", params: { token: token }
    expect(response).to have_http_status(:ok)
    response.parsed_body['birthdays']
  end

  # Before #101 the chip was dated in today's year (2026-01-03), which is
  # not in the December 2026 grid, so it was not drawn.
  it 'puts a January birthday in the next year on the December grid' do
    travel_to Time.zone.local(2026, 12, 20, 12, 0) do
      token
      create(:resident, community: community, unit: unit, name: 'Jan Born', birthday: Date.new(1990, 1, 3))

      # The December 2026 grid runs from Sunday Nov 29, 2026 to Saturday Jan 9, 2027.
      expect(birthday_chips('2026-12-15').pluck('start')).to eq(['2027-01-03'])
    end
  end

  # Before #101, viewed in 2026, a March 2027 birthday was dated
  # 2026-03-10, a year before the month on screen.
  it 'puts a birthday in the year of a month in another year' do
    travel_to Time.zone.local(2026, 12, 20, 12, 0) do
      token
      create(:resident, community: community, unit: unit, name: 'Mar Born', birthday: Date.new(1990, 3, 10))

      expect(birthday_chips('2027-03-15').pluck('start')).to eq(['2027-03-10'])
    end
  end

  # Before #101 the chip counted the age on today's date, so a birthday
  # later in the month showed last year's number.
  it 'names the age the person turns on the day of the chip' do
    travel_to Time.zone.local(2026, 4, 10, 12, 0) do
      token
      create(:resident, community: community, unit: unit, name: 'Dee Park', birthday: Date.new(2016, 4, 20))
      create(:resident, community: community, unit: unit, name: 'Fay Tan', birthday: Date.new(2004, 4, 11))

      titles = birthday_chips('2026-04-15').pluck('title')

      # Dee turns 10 on April 20, 2026. Fay turns 22 on April 11, 2026,
      # and from 22 on a chip shows no age.
      expect(titles).to contain_exactly("Dee's 10th B-day!", "Fay's B-day!")
    end
  end
end
