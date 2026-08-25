# frozen_string_literal: true

require 'rails_helper'

# Every wall-clock time is read in the community's zone (CLAUDE.md). The
# API gets that from ApiController#set_community_timezone; admin had no
# such wrapper, so a time typed into an admin form was parsed in the app's
# fixed zone (Pacific), and a time shown on an admin page was in it too.
# With the community in New York, "18:00" saved as 18:00 Pacific — 21:00
# for the people the reservation is for (time hunt, 2026-08-26).
RSpec.describe 'Admin forms and the community zone' do
  let(:community) { create(:community, timezone: 'America/New_York') }
  let(:unit) { create(:unit, community: community) }
  let(:admin_user) { create(:admin_user, community: community, superuser: true) }
  let(:resident) { create(:resident, community: community, unit: unit, multiplier: 2) }
  let(:new_york) { ActiveSupport::TimeZone['America/New_York'] }

  before do
    host! 'admin.example.com'
    sign_in admin_user
  end

  it 'stores a common-house reservation at the typed time in the community zone' do
    post '/common_house_reservations',
         params: { common_house_reservation: { resident_id: resident.id, title: 'Board games',
                                               start_date: '2026-04-12 18:00', end_date: '2026-04-12 21:00' } }

    reservation = CommonHouseReservation.last
    expect(reservation.start_date).to eq(new_york.local(2026, 4, 12, 18, 0))
    expect(reservation.end_date).to eq(new_york.local(2026, 4, 12, 21, 0))
  end

  it 'stores an event at the typed time in the community zone, on a DST-switch day too' do
    post '/events',
         params: { event: { title: 'Spring forward', start_date: '2026-03-08 10:00', end_date: '2026-03-08 12:00',
                            allday: false } }

    event = Event.last
    expect(event.start_date).to eq(new_york.local(2026, 3, 8, 10, 0))
    expect(event.end_date).to eq(new_york.local(2026, 3, 8, 12, 0))
  end

  it 'shows a stored time in the community zone' do
    reservation = create(:common_house_reservation, community: community, resident: resident,
                                                    start_date: new_york.local(2026, 4, 12, 18),
                                                    end_date: new_york.local(2026, 4, 12, 21))

    get "/common_house_reservations/#{reservation.id}"

    expect(response.body).to include('18:00')
    expect(response.body).not_to include('15:00')
  end
end
